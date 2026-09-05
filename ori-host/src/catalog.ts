/**
 * Models, providers, thinking levels -- and the three pi config files they are
 * derived from.
 *
 * ------------------------------------------------------------------ why files
 * pi's RPC cannot answer "which models does the user actually want offered".
 * `get_available_models` is filtered by pi to providers with CONFIGURED AUTH,
 * and that phrase means "a credential exists somewhere", not "the credential
 * works": measured, 5 providers / 116 models came back, of which 42 rows were
 * dead (expired OAuth on anthropic and openai-codex, a GEMINI_API_KEY that is
 * set and rejected with API_KEY_INVALID). A presence check cannot tell a good
 * key from a bad one -- only spending a request can -- so the filter is the
 * user's own curation instead, and it lives in two files pi already owns:
 *
 *   settings.json  `enabledModels`, the list pi feeds to its scoped-model set
 *                  (main.js: `parsed.models ?? settingsManager.getEnabledModels()`).
 *                  Entries are PATTERNS -- exact `provider/id` or a trailing `*`.
 *   models.json    `providers`, the hand-written endpoint/key file. Used only
 *                  when `enabledModels` is absent.
 *
 * Reading another program's config is coupling worth being uneasy about. It is
 * mitigated the only way it can be: if either shape changes, the filter matches
 * nothing and `usableModels` falls back to the UNFILTERED list rather than to an
 * empty one. A completion list with too much in it beats a command with no
 * values at all.
 *
 * models.json is read ONCE here and shared (both the provider list and the
 * ollama apiKey). The old code had two independent readers of that file --
 * PiSession's `piModelsFile` and Usage.qml's `keyFile` -- watching, parsing and
 * disagreeing about the same bytes.
 *
 * ---------------------------------------------------------------- why watched
 * These are edited by hand while the shell is up; during the session the old
 * comment was written in, one file lost three providers and the other ten
 * models. A completion list that is only correct after a shell reload is one
 * that is quietly wrong in between.
 */

import { watch } from "node:fs";
import { dirname, basename } from "node:path";
import type { ModelChoice } from "./protocol";

/**
 * pi's universal scale, minus what the endpoint refuses (below). This is what
 * `/effort` offers on a panel that has never run a child.
 *
 * Deliberately no "max": it is in pi's own enum and Ollama Cloud accepts it,
 * but the QML this replaces never offered it cold and adding it here would be a
 * behaviour change smuggled in under a port.
 */
const UNIVERSAL_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"];

/**
 * Levels the ENDPOINT has told us it does not accept, learned the only way
 * there is -- by being refused. pi's list describes what pi can ASK for, not
 * what a provider will take. Ollama Cloud answered `/effort minimal` with,
 * verbatim:
 *
 *   400 invalid reasoning value: 'minimal'
 *   (must be "high", "medium", "low", "max", or "none")
 *
 * Seeded from that measurement rather than left empty, because the first person
 * to find each one out pays a failed turn for it and one of them is paid.
 */
export const REJECTED_LEVELS = ["minimal", "xhigh"];

/** How long to sit on filesystem events before re-reading. Editors fire several
 *  per save (write, rename-into-place, attribute change); 50 ms collapses a
 *  save into one read and is still far below human notice. */
const WATCH_DEBOUNCE_MS = 50;

/** Persisting the choice is not urgent -- nothing reads the file until the next
 *  cold start -- so coalesce a burst of Shift+Tab presses into one write. */
const PERSIST_DEBOUNCE_MS = 250;

export interface CatalogPaths {
  /** ~/.pi/agent/settings.json */
  settings: string;
  /** ~/.pi/agent/models.json */
  models: string;
  /** ~/.pi/agent/subagents/registry.json */
  registry: string;
  /** The chosen provider/model/effort. Small, rewritten often. */
  choice: string;
  /** The catalogue those choices are validated against. ~10 KB, rewritten only
   *  when a live child hands us a new list. */
  cache: string;
}

export function defaultPaths(env: Record<string, string | undefined> = Bun.env): CatalogPaths {
  const home = env["HOME"] ?? "";
  const state = (env["XDG_STATE_HOME"] || `${home}/.local/state`) + "/ori-host";
  return {
    settings: `${home}/.pi/agent/settings.json`,
    models: `${home}/.pi/agent/models.json`,
    registry: `${home}/.pi/agent/subagents/registry.json`,
    choice: `${state}/ori-model.json`,
    cache: `${state}/ori-catalog.json`,
  };
}

/** Everything that touches the world, so the catalogue itself is testable with
 *  no filesystem and no clock. */
export interface CatalogIo {
  /** null when the file does not exist -- which is the NORMAL state for the
   *  subagent registry (nothing has been delegated) and must not be an error. */
  readText(path: string): Promise<string | null>;
  writeText(path: string, text: string): Promise<void>;
  /** Watch a directory, non-recursively, calling back with the basename that
   *  changed. Returns an unwatch function. */
  watchDir(dir: string, onEvent: (name: string) => void): () => void;
  /** Returns a cancel function rather than a handle, so no timer type leaks
   *  into the interface. */
  setTimer(fn: () => void, ms: number): () => void;
}

export const defaultCatalogIo: CatalogIo = {
  async readText(path) {
    const f = Bun.file(path);
    return (await f.exists()) ? await f.text() : null;
  },
  async writeText(path, text) {
    await Bun.write(path, text);
  },
  watchDir(dir, onEvent) {
    // The DIRECTORY, not the file. fs.watch on a path follows the inode, and
    // every editor and every atomic writer replaces the file by renaming a new
    // one over it -- so a per-file watch survives exactly one save and then
    // watches an unlinked inode nobody writes to again. Silently.
    //
    // A missing directory is not an error either: ~/.pi/agent/subagents does
    // not exist until something has been delegated, and fs.watch throws
    // ENOENT on it. No watcher then, and the file is still read at start.
    try {
      const w = watch(dir, { recursive: false }, (_event, name) => {
        if (name) onEvent(String(name));
      });
      w.on("error", () => w.close());
      return () => w.close();
    } catch {
      return () => {};
    }
  },
  setTimer(fn, ms) {
    const h = setTimeout(fn, ms);
    return () => clearTimeout(h);
  },
};

export type CatalogChange = "config" | "activity" | "choice" | "models";

interface ChoiceFile {
  provider?: unknown;
  modelId?: unknown;
  effort?: unknown;
  /** Old single-file format also carried the catalogue; read for migration. */
  models?: unknown;
  levels?: unknown;
  levelsFor?: unknown;
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function parseJson(text: string | null): unknown {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    // A corrupt file is not a reason to refuse to start. Every caller here
    // degrades to "unknown", which is the same state as "not read yet".
    return null;
  }
}

function toModels(raw: unknown): ModelChoice[] {
  if (!Array.isArray(raw)) return [];
  const out: ModelChoice[] = [];
  for (const item of raw) {
    const m = asRecord(item);
    if (!m || typeof m["provider"] !== "string" || typeof m["id"] !== "string") continue;
    out.push({
      provider: m["provider"],
      id: m["id"],
      name: typeof m["name"] === "string" ? m["name"] : m["id"],
    });
  }
  return out;
}

function toStrings(raw: unknown): string[] {
  return Array.isArray(raw) ? raw.filter((v): v is string => typeof v === "string") : [];
}

export interface CatalogOptions {
  paths?: CatalogPaths;
  io?: CatalogIo;
  watchDebounceMs?: number;
  persistDebounceMs?: number;
}

export class Catalog {
  readonly paths: CatalogPaths;
  readonly #io: CatalogIo;
  readonly #watchMs: number;
  readonly #persistMs: number;

  /* ---- read out of pi's config ---- */
  enabledModels: string[] = [];
  declaredProviders: string[] = [];
  /** providers.ollama.apiKey, shared with usage.ts so models.json has ONE reader. */
  ollamaApiKey = "";
  /** subagent handle -> what that delegate is doing right now. */
  agentActivity: Record<string, string> = {};

  /* ---- the catalogue a live child reported ---- */
  availableModels: ModelChoice[] = [];
  thinkingLevels: string[] = [];
  /** Which model `thinkingLevels` describes, "provider/id". A level list
   *  outlives the model it belongs to otherwise, and the cache is read back on
   *  a later day. */
  levelsFor = "";
  rejectedLevels: string[] = [...REJECTED_LEVELS];

  /* ---- the choice ---- */
  provider = "";
  model = "";
  /** The level the USER pinned with /effort; "" means "let pi choose". Only
   *  this reaches the command line. Seeding it from whatever get_state reported
   *  would freeze pi's own default the first time the panel was opened and
   *  override it silently forever after. */
  effort = "";
  /** The EFFECTIVE level as the child last reported it.
   *
   *  pi acks `set_thinking_level` with success:true for EVERY string and clamps
   *  silently -- an unsupported level is neither an error nor the level you
   *  asked for. Only `get_state` and the `thinking_level_changed` event are
   *  trustworthy, so this field is written from those two and never from an ack. */
  thinkingLevel = "";

  /** How many times the watched config files were actually re-read. Public
   *  because it is the only observable that distinguishes "debounced" from
   *  "nothing happened" -- the debounce test asserts on it. */
  reloadCount = 0;

  #listeners: ((what: CatalogChange) => void)[] = [];
  #unwatch: (() => void)[] = [];
  #cancelTimers = new Map<string, () => void>();
  #choiceDirty = false;
  #cacheDirty = false;

  constructor(opts: CatalogOptions = {}) {
    this.paths = opts.paths ?? defaultPaths();
    this.#io = opts.io ?? defaultCatalogIo;
    this.#watchMs = opts.watchDebounceMs ?? WATCH_DEBOUNCE_MS;
    this.#persistMs = opts.persistDebounceMs ?? PERSIST_DEBOUNCE_MS;
  }

  onChange(cb: (what: CatalogChange) => void): void {
    this.#listeners.push(cb);
  }

  /** Read everything once, then arm the watchers. */
  async start(): Promise<void> {
    await this.#loadPersisted();
    await this.reloadConfig();
    await this.reloadRegistry();

    this.#watchFiles([this.paths.settings, this.paths.models], "config", () =>
      this.reloadConfig(),
    );
    this.#watchFiles([this.paths.registry], "activity", () => this.reloadRegistry());
  }

  /** Cancel the watchers and flush anything still owed to disk. */
  async stop(): Promise<void> {
    for (const off of this.#unwatch) off();
    this.#unwatch = [];
    for (const cancel of this.#cancelTimers.values()) cancel();
    this.#cancelTimers.clear();
    await this.#persistNow();
  }

  /* ------------------------------------------------------------------ reads */

  async reloadConfig(): Promise<void> {
    this.reloadCount++;

    const settings = asRecord(parseJson(await this.#io.readText(this.paths.settings)));
    const enabled = toStrings(settings?.["enabledModels"]);

    // ONE read of models.json, feeding both consumers.
    const models = asRecord(parseJson(await this.#io.readText(this.paths.models)));
    const providers = asRecord(models?.["providers"]) ?? {};
    const declared = Object.keys(providers);
    const ollama = asRecord(providers["ollama"]);
    const key = typeof ollama?.["apiKey"] === "string" ? (ollama["apiKey"] as string) : "";

    const changed =
      !sameStrings(enabled, this.enabledModels) ||
      !sameStrings(declared, this.declaredProviders) ||
      key !== this.ollamaApiKey;

    this.enabledModels = enabled;
    this.declaredProviders = declared;
    this.ollamaApiKey = key;
    if (changed) this.#emit("config");
  }

  async reloadRegistry(): Promise<void> {
    this.reloadCount++;
    const reg = asRecord(parseJson(await this.#io.readText(this.paths.registry))) ?? {};
    const out: Record<string, string> = {};
    for (const [handle, value] of Object.entries(reg)) {
      const rec = asRecord(value);
      // Only a LIVE one. A record keeps its handle for a day after it finishes
      // so it can be resumed, and none of those belong on a strip that says
      // what is running.
      if (rec && rec["status"] === "running" && typeof rec["activity"] === "string" && rec["activity"])
        out[handle] = rec["activity"];
    }
    const changed = JSON.stringify(out) !== JSON.stringify(this.agentActivity);
    this.agentActivity = out;
    if (changed) this.#emit("activity");
  }

  /* ---------------------------------------------------------------- filters */

  /** Exact `provider/id`, or a trailing-`*` prefix. That covers what
   *  `enabledModels` actually holds and degrades to "no match" rather than to a
   *  WRONG match, which a looser glob would not. */
  modelEnabled(key: string): boolean {
    for (const pattern of this.enabledModels) {
      if (pattern === key) return true;
      if (pattern.endsWith("*") && key.startsWith(pattern.slice(0, -1))) return true;
    }
    return false;
  }

  /**
   * What `/model` OFFERS -- not what it ACCEPTS. `parseCommand` validates
   * against the full `availableModels`, so naming a hidden model in full still
   * works. The asymmetry is deliberate: completion must not hand anyone a dead
   * provider, and typing `anthropic/claude-haiku-4-5` out by hand is not done
   * by accident.
   */
  get usableModels(): ModelChoice[] {
    const scoped = this.enabledModels.length > 0;
    const out = this.availableModels.filter(
      (m) =>
        // The model Ori is ON is always offered, however it got there. A picker
        // that cannot show the current selection has a hole in it.
        (m.provider === this.provider && m.id === this.model) ||
        (scoped
          ? this.modelEnabled(`${m.provider}/${m.id}`)
          : this.declaredProviders.includes(m.provider)),
    );
    // A filter that matched nothing is a broken filter, not an empty machine.
    // If either config file moves or changes shape, offering everything is a
    // far better failure than offering a command with no values at all.
    return out.length > 0 ? out : this.availableModels;
  }

  /** The levels to offer. The model's own list once one has been read,
   *  otherwise pi's universal scale, so `/effort` and Shift+Tab work on a panel
   *  that has never run a child. */
  effortScale(): string[] {
    if (this.thinkingLevels.length > 0) return this.thinkingLevels;
    return UNIVERSAL_LEVELS.filter((l) => !this.rejectedLevels.includes(l));
  }

  /* ---------------------------------------------------------------- writers */

  /** From `get_available_models`. Trimmed to the three fields anything reads:
   *  the live answer is 45 KB of baseUrls, per-token costs and window sizes. */
  applyModels(list: readonly { provider: string; id: string; name?: string }[]): void {
    if (list.length === 0) return; // an empty answer is a failed probe, not a change
    this.availableModels = list.map((m) => ({
      provider: m.provider,
      id: m.id,
      name: m.name ?? m.id,
    }));
    this.#cacheDirty = true;
    this.#schedulePersist();
    this.#emit("models");
  }

  /** From `get_available_thinking_levels`, minus what this endpoint refuses. */
  applyLevels(list: readonly string[]): void {
    if (list.length === 0) return;
    this.thinkingLevels = list.filter((l) => !this.rejectedLevels.includes(l));
    this.levelsFor = `${this.provider}/${this.model}`;
    this.#cacheDirty = true;
    this.#schedulePersist();
    this.#emit("models");
  }

  /**
   * A pinned level the endpoint refuses is worse than no level at all: it is
   * written into the child's argv as `--thinking <level>`, so it poisons every
   * future spawn and every turn 400s until someone notices. Unpin it and
   * remember it.
   */
  rejectLevel(level: string): void {
    if (level !== "" && !this.rejectedLevels.includes(level)) this.rejectedLevels.push(level);
    this.thinkingLevels = this.thinkingLevels.filter((l) => l !== level);
    if (this.effort === level) {
      this.effort = "";
      this.#choiceDirty = true;
    }
    this.#cacheDirty = true;
    this.#schedulePersist();
    this.#emit("models");
  }

  /** From `get_state` -- the one reading that cannot be wrong. */
  applyState(s: { provider?: string; model?: string; thinkingLevel?: string }): void {
    let changed = false;
    if (s.provider && s.model && (s.provider !== this.provider || s.model !== this.model)) {
      this.provider = s.provider;
      this.model = s.model;
      changed = true;
    }
    if (s.thinkingLevel !== undefined && s.thinkingLevel !== this.thinkingLevel) {
      this.thinkingLevel = s.thinkingLevel;
      changed = true;
    }
    if (!changed) return;
    this.#choiceDirty = true;
    this.#schedulePersist();
    this.#emit("choice");
  }

  /** The pinned level. Validation belongs to `parseCommand`, which owns the
   *  message; by the time it gets here the level is one of `effortScale()`. */
  setEffort(level: string): void {
    if (level === this.effort && level === this.thinkingLevel) return;
    this.effort = level;
    // Shown immediately, so a cold panel is not silent for the ten minutes
    // before the next question spawns a child that can confirm it. get_state
    // corrects this at that spawn if pi disagrees.
    this.thinkingLevel = level;
    this.#choiceDirty = true;
    this.#schedulePersist();
    this.#emit("choice");
  }

  /**
   * The state half of a model switch, shared by the cold path and the
   * `set_model` response.
   *
   * The level and its list both belonged to the model being left, and pi drops
   * the level too on a switch -- setModel() re-derives it from the per-model
   * override then the global default, and was watched doing it: deepseek at
   * "off" became claude-haiku-4-5 at "high", unasked. Keeping a stale pin here
   * would fight that for no reason and display a level the child does not have.
   */
  applyModelChoice(provider: string, id: string): void {
    this.provider = provider;
    this.model = id;
    this.effort = "";
    this.thinkingLevel = "";
    this.thinkingLevels = [];
    this.levelsFor = "";
    this.#choiceDirty = true;
    this.#cacheDirty = true;
    this.#schedulePersist();
    this.#emit("choice");
  }

  /* ------------------------------------------------------------- persistence
   * TWO files, because they change at wildly different rates. The old code kept
   * one and rewrote the whole ~10 KB catalogue on every effort change -- i.e.
   * on every Shift+Tab. The choice is ~120 bytes and moves constantly; the
   * catalogue moves once per cold spawn.
   */

  async #loadPersisted(): Promise<void> {
    const choice = (asRecord(parseJson(await this.#io.readText(this.paths.choice))) ??
      {}) as ChoiceFile;
    // Only a COMPLETE pair is restored. Half of it -- a provider with no id --
    // builds `--provider anthropic --model deepseek-...`, and pi does NOT fail
    // on that: it warns on stderr, which nothing reads, and starts anyway on a
    // fabricated "custom model id" pointed at the wrong baseUrl.
    if (typeof choice.provider === "string" && typeof choice.modelId === "string") {
      this.provider = choice.provider;
      this.model = choice.modelId;
    }
    if (typeof choice.effort === "string") this.effort = choice.effort;

    const cacheRaw = asRecord(parseJson(await this.#io.readText(this.paths.cache)));
    // Fall back to the old single-file format, which carried the catalogue in
    // the choice file, so an existing install keeps its lists across the port.
    const cache = cacheRaw ?? (choice as Record<string, unknown>);
    this.availableModels = toModels(cache["models"]);
    this.thinkingLevels = toStrings(cache["levels"]);
    this.levelsFor = typeof cache["levelsFor"] === "string" ? cache["levelsFor"] : "";
  }

  #schedulePersist(): void {
    this.#debounce("persist", this.#persistMs, () => void this.#persistNow());
  }

  async #persistNow(): Promise<void> {
    // Swallowed, because this runs detached from any caller (the debounce
    // timer) and a rejected write here would surface as an unhandled rejection
    // and take the host down over a cache file. Nothing reads either file until
    // the next cold start, and every cold spawn rewrites both.
    try {
      if (this.#choiceDirty) {
        this.#choiceDirty = false;
        await this.#io.writeText(
          this.paths.choice,
          JSON.stringify({
            version: 1,
            provider: this.provider,
            modelId: this.model,
            effort: this.effort,
          }),
        );
      }
      if (this.#cacheDirty) {
        this.#cacheDirty = false;
        await this.#io.writeText(
          this.paths.cache,
          JSON.stringify({
            version: 1,
            levelsFor: this.levelsFor,
            levels: this.thinkingLevels,
            models: this.availableModels,
          }),
        );
      }
    } catch {
      /* see above */
    }
  }

  /* ------------------------------------------------------------------ plumbing */

  #watchFiles(paths: string[], key: string, reload: () => Promise<void>): void {
    // Group by directory: settings.json and models.json share one, so they
    // share one watcher and one debounce -- a save that touches both is one read.
    const byDir = new Map<string, Set<string>>();
    for (const p of paths) {
      const dir = dirname(p);
      const set = byDir.get(dir) ?? new Set<string>();
      set.add(basename(p));
      byDir.set(dir, set);
    }
    for (const [dir, names] of byDir) {
      this.#unwatch.push(
        this.#io.watchDir(dir, (name) => {
          if (!names.has(name)) return;
          // Detached from any caller, so a rejected read must not become an
          // unhandled rejection: the state simply stays as it was.
          this.#debounce(key, this.#watchMs, () => void reload().catch(() => {}));
        }),
      );
    }
  }

  /** One pending timer per key; a new event pushes the deadline out. */
  #debounce(key: string, ms: number, fn: () => void): void {
    this.#cancelTimers.get(key)?.();
    this.#cancelTimers.set(
      key,
      this.#io.setTimer(() => {
        this.#cancelTimers.delete(key);
        fn();
      }, ms),
    );
  }

  #emit(what: CatalogChange): void {
    for (const cb of this.#listeners) cb(what);
  }
}

function sameStrings(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}
