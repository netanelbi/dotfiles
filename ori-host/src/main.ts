/**
 * main.ts -- wiring, and as close to nothing else as the seams allow.
 *
 * Every rule this host obeys is argued for in the module that owns it. Nothing
 * here re-decides any of them: this file creates the store, the catalogue, the
 * pool and the socket, points them at each other, and routes `ClientCmd`s in and
 * `HostEvent`s out.
 *
 * The one piece of real code below is `Agent`, and it exists because two
 * interfaces deliberately do not know about each other:
 *
 *   - `pool.ts` declares a narrow `Conversation` (id, busy, snapshot, killChild)
 *     so the pool can be tested with no child process at all.
 *   - `conversation.ts` is a pure state machine that has never heard of a pi
 *     process -- its outbound RPC goes through an injected `send`.
 *
 * `Agent` is the join: one pi child, one conversation state machine, one detach
 * file. It holds no policy of its own; where it has to choose, the reason is
 * written down and points at the module the rule came from.
 */

import { existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import {
  Catalog,
  defaultPaths,
  type CatalogChange,
  type CatalogPaths,
} from "./catalog";
import { panelCommands, parseCommand, type Intent } from "./commands";
import {
  Conversation as ConvState,
  type PiCommand,
  type PiEvent,
  type PiResponse,
} from "./conversation";
import { DetachChannel } from "./detach";
import { capture, encode as encodeImage, ImageStaging } from "./images";
import { log } from "./log";
import { buildWorkdir, type PiSpawnConfig } from "./pi/argv";
import { PiChild, type PiExit } from "./pi/child";
import { isRpcResponse, type PiFrame, type RpcCommand } from "./pi/pi-types";
import { Pool, type ConversationHooks, type ConvSpec, type Conversation as PoolConv, type Snapshot } from "./pool";
import {
  PROTOCOL_VERSION,
  type ClientCmd,
  type HostEvent,
  type ImageRef,
  type SlashCommand,
} from "./protocol";
import { rehydrate } from "./rehydrate";
import {
  deriveLabel,
  piSessionDir,
  readLegacyIndex,
  readTranscript,
  scanSessions,
  Store,
  summarise,
  type FileStamp,
} from "./store";
import { serve, socketPath, type Conn, type OriServer } from "./transport";
import { defaultUsageIo, OllamaUsage, type UsageIo } from "./usage";

/**
 * PiSession.qml:1018. A steer means "stop what you are doing and read this", so
 * a bash call in flight is given a third of a second to wrap up before it is
 * backgrounded out of the way. Short enough that the redirect is not sitting
 * behind a build; long enough that a command about to finish still gets to.
 */
const STEER_DETACH_GRACE_MS = 300;

/** Set once the ori-sessions.json migration has run, so it is read exactly one
 *  time in the life of an index rather than on every start. */
const LEGACY_MIGRATED = "legacyIndexMigrated";

/** pi's `ImageContent`, which is what `prompt`/`steer` carry. */
interface ImagePayload {
  type: "image";
  data: string;
  mimeType: string;
}

/* ------------------------------------------------------------------ *
 * Agent -- one pi child bound to one conversation
 * ------------------------------------------------------------------ */

/** Everything an `Agent` needs from the host, injected rather than reached for,
 *  so nothing below imports the host back. */
interface AgentEnv {
  catalog: Catalog;
  /** Already gated on "is this the active conversation". */
  emit: (ev: HostEvent) => void;
  hooks: ConversationHooks;
  home: string;
  runtimeDir: string;
  /** Fixed pi argv overrides. Only the e2e smoke test sets any of these. */
  spawn: Partial<PiSpawnConfig>;
  onEntries: (agent: Agent, entries: unknown[]) => void;
}

class Agent implements PoolConv {
  readonly id: string;
  readonly sessionId: string;
  readonly conv: ConvState;

  #child: PiChild | null = null;
  #detach: DetachChannel | null = null;
  /** The JSONL this conversation resumes from, until pi reports its own. */
  readonly #resumeFile: string;
  /** A resumed conversation asks for its transcript on the first spawn and only
   *  then; every later spawn of the same child is a cold restart of a session pi
   *  already holds. */
  #needEntries: boolean;
  readonly #env: AgentEnv;

  constructor(spec: ConvSpec, env: AgentEnv) {
    this.id = spec.convId;
    this.sessionId = spec.sessionId;
    this.#resumeFile = spec.sessionFile;
    this.#needEntries = spec.sessionFile !== "";
    this.#env = env;

    this.conv = new ConvState(spec.convId, env.emit, {
      send: (cmd) => this.send(cmd),
      onEntries: (entries) => env.onEntries(this, entries),
    });
    // The panel's footer names a directory, and it must be the one the child
    // will actually run in -- known before any child exists, because argv.ts is
    // a pure function of the config.
    this.conv.patchState({
      sessionId: spec.sessionId,
      sessionFile: spec.sessionFile,
      workdir: buildWorkdir(this.#cfg()),
    });
  }

  /* --------------------------------------------------- pool's Conversation */

  /** pi's own answer once there is one; the resume path until then. */
  get sessionFile(): string {
    return this.conv.state.sessionFile || this.#resumeFile;
  }

  get busy(): boolean {
    return this.conv.state.busy;
  }

  get childAlive(): boolean {
    return this.#child?.running === true;
  }

  label(): string {
    for (const t of this.conv.turns) {
      if (t.role === "user" && t.text !== "") return deriveLabel(t.text);
    }
    return "";
  }

  /** User turns, i.e. exchanges -- the same thing `store.summarise` counts, so a
   *  row written from memory and one written from a transcript agree. */
  turnCount(): number {
    let n = 0;
    for (const t of this.conv.turns) if (t.role === "user") n++;
    return n;
  }

  snapshot(): Snapshot {
    return this.conv.snapshot() as Snapshot;
  }

  killChild(why: string): void {
    const child = this.#child;
    if (!child) return;
    log.info("killing pi child", { conv: this.id, pid: child.pid, why });
    // Not awaited: the exit lands on `onExit` like any other death, and every
    // caller of this (the idle clock, the orphan reap, /restart) is synchronous.
    void child.kill().catch((e: unknown) => log.warn("kill failed", { err: String(e) }));
  }

  /**
   * Reuses conversation.ts's OWN failure path -- a rejected RPC -- rather than
   * adding a second one beside it. That path clears `busy`, settles the open
   * turn and paints the error strip, which is exactly what a turn whose child
   * died needs, and it cannot drift away from the case it shares code with.
   */
  failTurn(why: string): void {
    this.conv.handleResponse({ type: "response", command: "prompt", success: false, error: why });
  }

  dispose(): void {
    this.killChild("disposed");
    this.#detach?.close();
    this.#detach = null;
  }

  /* ----------------------------------------------------------------- pi io */

  /** Fire and forget. A dead child is not an error here -- `/effort` and
   *  `/model` are expected to work cold, and the setting reaches pi as the next
   *  spawn's argv instead. */
  send(cmd: PiCommand): void {
    const child = this.#child;
    if (child?.running !== true) {
      log.debug("dropped command, no child", { conv: this.id, type: cmd.type });
      return;
    }
    try {
      child.send(cmd as unknown as RpcCommand);
    } catch (e) {
      log.warn("send failed", { conv: this.id, type: cmd.type, err: String(e) });
    }
  }

  /**
   * A question. The HOST decides prompt-vs-steer, from conversation.ts's `busy`
   * -- the panel does not know and must not guess (protocol.ts).
   */
  ask(text: string, images: ImageRef[], payload: ImagePayload[]): void {
    const { turnId, steer } = this.conv.ask(text, images);
    // AFTER conv.ask, so the five startup probes queue ahead of the question
    // exactly as they did in the broker: they are local lookups on a child that
    // is booting anyway (measured 2.57s -> 2.62s to first token).
    this.#ensureChild();
    this.send(
      steer
        ? { type: "steer", message: text, images: payload }
        : { type: "prompt", message: text, images: payload },
    );
    this.conv.markSent(turnId);
    // A steer is "stop and read this", so the bash call holding the turn is
    // asked to get out of the way. Best effort by construction: no detach file
    // means no env var means the extension never armed.
    if (steer) this.#detach?.detach(STEER_DETACH_GRACE_MS, this.#child?.pid ?? 0);
  }

  #cfg(): PiSpawnConfig {
    const cat = this.#env.catalog;
    return {
      provider: cat.provider,
      model: cat.model,
      effort: cat.effort,
      sessionId: this.sessionId,
      detachPath: this.#detach?.path,
      home: this.#env.home,
      exists: existsSync,
      ...this.#env.spawn,
    };
  }

  #ensureChild(): void {
    if (this.#child?.running === true) return;

    // Created BEFORE the child, because the extension's fs.watch throws on a
    // missing path and attaches once, at load (detach.ts).
    this.#detach = DetachChannel.open({
      runtimeDir: this.#env.runtimeDir,
      onError: (why) => log.warn(why, { conv: this.id }),
    });

    const cfg = this.#cfg();
    const child = new PiChild(cfg, {
      onFrame: (f) => this.#onFrame(f),
      onExit: (x) => this.#onExit(x),
    });
    this.#child = child;
    child.start();
    this.conv.patchState({ warm: true, workdir: buildWorkdir(cfg) });

    // PiSession.onPiStarted(). All five are knowable the moment a child is up,
    // none can change without a spawn, and they were measured landing
    // 0.62-0.79s after spawn against a first token 6.8s out.
    const first: RpcCommand = this.#needEntries
      ? { type: "get_entries" }
      : { type: "get_session_stats" };
    this.#needEntries = false;
    for (const probe of [
      first,
      { type: "get_commands" },
      { type: "get_state" },
      { type: "get_available_thinking_levels" },
      { type: "get_available_models" },
    ] as RpcCommand[]) {
      this.send(probe);
    }
  }

  #onFrame(frame: PiFrame): void {
    // Any frame, either direction, is life: it resets the 600s idle clock.
    this.#env.hooks.onActivity();

    if (isRpcResponse(frame)) {
      const res = frame as unknown as PiResponse;
      this.conv.handleResponse(res);
      this.#mirrorCatalog(res);
      return;
    }

    const ev = frame as unknown as PiEvent;
    this.conv.handleEvent(ev);
    // THE idle signal, not `agent_end` (ARCHITECTURE.md). conversation.ts has
    // already cleared `busy` by the time this runs, which is what the pool's
    // hook contract requires.
    if (ev.type === "agent_settled") this.#env.hooks.onSettled();
    if (ev.type === "thinking_level_changed") {
      this.#env.catalog.applyState({ thinkingLevel: ev.level ?? "" });
    }
  }

  /**
   * The catalogue outlives the child; the conversation does not. These three
   * answers are what `/model` and `/effort` need to still work ten minutes after
   * the idle kill, so they are copied out of the response stream as it passes.
   */
  #mirrorCatalog(res: PiResponse): void {
    if (res.success === false) return;
    switch (res.command) {
      case "get_available_models": {
        const list = ((res.data ?? {}) as { models?: { provider: string; id: string; name?: string }[] })
          .models;
        if (list) this.#env.catalog.applyModels(list);
        return;
      }
      case "get_available_thinking_levels": {
        const list = ((res.data ?? {}) as { levels?: string[] }).levels;
        if (list) this.#env.catalog.applyLevels(list);
        return;
      }
      case "get_state": {
        const s = (res.data ?? {}) as {
          model?: { provider?: string; id?: string };
          thinkingLevel?: string;
        };
        this.#env.catalog.applyState({
          provider: s.model?.provider ?? "",
          model: s.model?.id ?? "",
          thinkingLevel: s.thinkingLevel ?? "",
        });
        return;
      }
      default:
        return;
    }
  }

  #onExit(exit: PiExit): void {
    const wasBusy = this.conv.state.busy;
    // Cleared BEFORE the hook: pool.ts reads `childAlive` from inside
    // `onChildExit` and must see false.
    this.#child = null;
    this.#detach?.close();
    this.#detach = null;
    this.conv.patchState({ warm: false });
    // An exit while busy is a crash or the idle kill misfiring, not a normal
    // end. Saying so beats leaving the panel spinning on an answer that will
    // never come (PiSession.onPiExited).
    if (wasBusy) {
      this.failTurn(`pi exited (code=${exit.exitCode} signal=${exit.signalCode})`);
    }
    this.#env.hooks.onChildExit();
  }
}

/* ------------------------------------------------------------------ *
 * Host
 * ------------------------------------------------------------------ */

export interface HostOptions {
  /** Defaults to `$XDG_RUNTIME_DIR/ori-agent.sock`. */
  socket?: string;
  /** Defaults to `$XDG_STATE_HOME/ori-host/sessions.db`. */
  dbPath?: string;
  /** pi's session directory for this workdir. Defaults to
   *  `$PI_CODING_AGENT_SESSION_DIR`, else `~/.pi/agent/sessions/<encoded cwd>`. */
  sessionDir?: string;
  /** The QML panel's old index, migrated once. Defaults to
   *  `<home>/.local/state/quickshell/ori-sessions.json`. */
  legacyIndex?: string;
  home?: string;
  runtimeDir?: string;
  catalogPaths?: CatalogPaths;
  /** pi argv overrides. Only the e2e smoke test sets any of these -- it points
   *  `binary` at a fake child so the suite never spawns a real agent. */
  spawn?: Partial<PiSpawnConfig>;
  usageIo?: UsageIo;
}

export class Host {
  readonly store: Store;
  readonly catalog: Catalog;
  readonly pool: Pool;

  readonly #socket: string;
  readonly #home: string;
  readonly #runtimeDir: string;
  readonly #spawn: Partial<PiSpawnConfig>;
  readonly #staging = new ImageStaging();
  readonly #usage: OllamaUsage;
  #server: OriServer | null = null;

  readonly #sessionDir: string;
  readonly #legacyIndex: string;
  /** What the last scan saw, so the next one only opens files that moved. */
  #stamps: ReadonlyMap<string, FileStamp> = new Map();
  /** A scan in flight, so concurrent callers join it instead of stacking. */
  #scanning: Promise<void> | null = null;
  /**
   * Transcript restores in flight, by conversation id.
   *
   * This map is the fix for a race that cost a resumed conversation its entire
   * history for the rest of its life: `#restore` reads the JSONL asynchronously
   * and then calls `conv.install()`, which REPLACES the turn list -- so it has
   * to refuse to run once a question has been asked, and refusing was permanent
   * because nothing ever tried again. The question now waits for the read
   * instead. Waiting is the right way round rather than retrying afterwards:
   * `install()` also resets `busy`, `liveId` and the steer queue (see its
   * comment), so there is no correct way to fold a file read into a
   * conversation that has already started a turn.
   */
  readonly #restoring = new Map<string, Promise<void>>();

  constructor(opts: HostOptions = {}) {
    this.#home = opts.home ?? Bun.env["HOME"] ?? "";
    this.#runtimeDir = opts.runtimeDir ?? Bun.env["XDG_RUNTIME_DIR"] ?? "";
    this.#socket = opts.socket ?? socketPath();
    this.#spawn = opts.spawn ?? {};
    this.#usage = new OllamaUsage(opts.usageIo ?? defaultUsageIo);

    // Derived, never hardcoded: the child's workdir decides which of pi's
    // session directories holds this host's conversations, and argv.ts already
    // owns that answer.
    const workdir = buildWorkdir({ home: this.#home, exists: existsSync, ...this.#spawn });
    this.#sessionDir =
      opts.sessionDir ??
      piSessionDir({ workdir, home: this.#home, env: Bun.env["PI_CODING_AGENT_SESSION_DIR"] });
    // Off `home` and not `$XDG_STATE_HOME`, unlike the db below: this path is
    // not ours to place. It is where Quickshell wrote the file we are reading,
    // and tests that pass a scratch `home` must not reach the real one.
    this.#legacyIndex = opts.legacyIndex ?? `${this.#home}/.local/state/quickshell/ori-sessions.json`;

    const dbPath = opts.dbPath ?? defaultDbPath(this.#home);
    // bun:sqlite will not create the directory; Bun.write (which the catalogue
    // uses) would.
    if (dbPath !== ":memory:") mkdirSync(dirname(dbPath), { recursive: true });
    this.store = new Store(dbPath);

    this.catalog = new Catalog(opts.catalogPaths ? { paths: opts.catalogPaths } : {});
    this.catalog.onChange((what) => this.#onCatalogChange(what));

    this.pool = new Pool({
      store: this.store,
      emit: (ev) => this.broadcast(ev),
      factory: (spec, hooks) => this.#makeAgent(spec, hooks),
    });
  }

  /* -------------------------------------------------------------- lifecycle */

  async start(): Promise<void> {
    await this.catalog.start();
    // One conversation exists before the socket does, so a `hello` is answered
    // with a snapshot rather than racing a lazy create. No child is spawned:
    // `Agent` stays cold until the first question.
    this.pool.create();
    this.#server = await serve({
      path: this.#socket,
      handlers: {
        onHello: (conn, channel, displaced) => this.#onHello(conn, channel, displaced),
        onCommand: (conn, cmd) => this.#onCommand(conn, cmd),
        onGone: () => this.pool.clientDisconnected(),
      },
    });
    // NOT awaited, and that is the requirement: the panel connects the moment
    // the socket exists, and discovery is up to 40 stats and 40 bounded reads.
    // Its result arrives as a `sessions` event whenever it lands.
    void this.discover();
  }

  /**
   * Everything the index can learn without being told: the old JSON index, then
   * pi's own session directory.
   *
   * Migration first because it carries the better data (real labels, real turn
   * counts) -- though `Store.seed` makes the order safe either way, since
   * neither pass may overwrite the other.
   */
  async discover(): Promise<void> {
    await this.#migrateLegacy();
    await this.rescan();
  }

  /**
   * Re-read pi's session directory. Cheap by design: a file whose mtime and
   * size are unchanged is never opened, so the steady-state cost is one stat per
   * session. Called on demand rather than by watching the directory -- the panel
   * asking for its session list is the only moment the answer is looked at.
   *
   * Deduped: a scan already running is joined, so a reconnect storm cannot stack
   * scans on top of each other.
   */
  rescan(): Promise<void> {
    const running = this.#scanning;
    if (running) return running;
    const run = this.#scanOnce().finally(() => {
      this.#scanning = null;
    });
    this.#scanning = run;
    return run;
  }

  async #scanOnce(): Promise<void> {
    try {
      const { found, stamps, read } = await scanSessions(this.#sessionDir, this.#stamps);
      this.#stamps = stamps;
      if (found.length === 0) return;
      this.store.seed(found);
      log.info("discovered sessions", { dir: this.#sessionDir, found: found.length, read });
      this.broadcast({
        t: "sessions",
        entries: this.pool.list(),
        activeId: this.#active()?.sessionId ?? "",
      });
    } catch (e) {
      // A host that cannot read pi's directory is a host with a short session
      // list, not a host that fails to start.
      log.warn("session scan failed", { dir: this.#sessionDir, err: String(e) });
    }
  }

  /** `~/.local/state/quickshell/ori-sessions.json`, read ONCE ever. */
  async #migrateLegacy(): Promise<void> {
    if (this.store.meta(LEGACY_MIGRATED) !== null) return;
    try {
      const rows = await readLegacyIndex(this.#legacyIndex);
      // Absent. Not recorded as done: the old panel may still be running and
      // about to write it, and re-checking costs one stat per start.
      if (rows === null) return;
      if (rows.length > 0) {
        this.store.seed(rows);
        log.info("migrated the old session index", { file: this.#legacyIndex, rows: rows.length });
      }
      this.store.setMeta(LEGACY_MIGRATED, String(Date.now()));
    } catch (e) {
      log.warn("session index migration failed", { file: this.#legacyIndex, err: String(e) });
    }
  }

  /** Closes the socket, unlinks its file, and SIGTERMs every child. */
  async stop(): Promise<void> {
    this.#server?.stop();
    this.#server = null;
    this.pool.shutdown();
    await this.catalog.stop();
    this.store.close();
  }

  get socketPath(): string {
    return this.#socket;
  }

  /* ------------------------------------------------------------------ fanout */

  broadcast(ev: HostEvent): void {
    const server = this.#server;
    if (!server) return;
    for (const conn of server.conns()) conn.send(ev);
  }

  /**
   * A conversation's own events, gated on it being the one on screen.
   *
   * A parked conversation keeps ingesting and keeps filling its turn list --
   * that is the whole point of parking -- but the panel draws exactly one
   * conversation, and its `activate` is served from a fresh snapshot. So parked
   * traffic is dropped here rather than sent for the panel to filter.
   */
  #emitFor(convId: string): (ev: HostEvent) => void {
    return (ev) => {
      if (this.pool.activeId !== convId) return;
      // pi's `get_commands` answers with SKILLS ONLY -- the child spawns with
      // `-ne` and no `--skill` -- so the panel's own rows have to be merged back
      // in here, or the first cold spawn would delete /model and /effort from
      // the completion list.
      if (ev.t === "commands") {
        this.broadcast({ t: "commands", commands: [...this.#panelCmds(), ...ev.commands] });
        return;
      }
      this.broadcast(ev);
    };
  }

  #panelCmds(): SlashCommand[] {
    return panelCommands({
      usable: this.catalog.usableModels,
      levels: this.catalog.effortScale(),
    });
  }

  #onCatalogChange(what: CatalogChange): void {
    // "activity" is the subagent registry, which feeds BgJob.activity -- not
    // wired to a HostEvent yet, and silently broadcasting the model list on it
    // would be noise.
    if (what === "activity") return;
    this.broadcast({ t: "models", models: this.catalog.availableModels });
    this.broadcast({ t: "commands", commands: this.#panelCmds() });
  }

  /* -------------------------------------------------------------- the pool */

  #makeAgent(spec: ConvSpec, hooks: ConversationHooks): PoolConv {
    return new Agent(spec, {
      catalog: this.catalog,
      emit: this.#emitFor(spec.convId),
      hooks: {
        onActivity: hooks.onActivity,
        onSettled: () => {
          hooks.onSettled();
          // The plan allowance moves for exactly one reason -- a turn was spent
          // against it -- so this is the only place it is asked for. Never a
          // timer (usage.ts).
          void this.#usage.refresh();
        },
        onChildExit: hooks.onChildExit,
      },
      home: this.#home,
      runtimeDir: this.#runtimeDir,
      spawn: this.#spawn,
      onEntries: (agent, entries) => this.#onEntries(agent, entries),
    });
  }

  /** Every conversation in the pool was made by `#makeAgent`, so this cast is
   *  total; the pool's own interface is deliberately narrower than `Agent`. */
  #active(): Agent | null {
    return (this.pool.active as Agent | null) ?? null;
  }

  /**
   * A resumed session's transcript, straight from pi.
   *
   * It updates the index row so the picker keeps its label and count. It does
   * NOT rebuild the turn list: `#restore` has already done that from the file,
   * and by the time this answer arrives the child has spawned, which means a
   * question may well be in flight -- `get_entries` is the FIRST probe of a cold
   * spawn and `ask()` spawns the child, so rebuilding here would delete the
   * question the user just asked.
   */
  #onEntries(agent: Agent, entries: unknown[]): void {
    const { label, turns } = summarise(entries);
    if (label === "" || agent.sessionFile === "") return;
    this.store.upsert({ id: agent.sessionId, file: agent.sessionFile, label, at: Date.now(), turns });
    this.broadcast({ t: "sessions", entries: this.pool.list(), activeId: agent.sessionId });
  }

  /**
   * Put a conversation that was only on disk back on screen.
   *
   * THE BLOCKER FOR MULTI-SESSION: the pool can build a cold `Agent` for a
   * session it no longer holds, but nothing filled its turn list, so activating
   * it showed an empty transcript until the next question. Reading the JSONL is
   * the only source available here -- asking pi would mean spawning a child, and
   * a session picker that costs a 2.5 s spawn per preview is not one.
   *
   * A no-op for anything already in memory, which is the common case: parked
   * conversations keep their turns and `pool.resume` hands the live one back.
   */
  #restore(agent: Agent | null): Promise<void> {
    if (!agent) return Promise.resolve();
    const running = this.#restoring.get(agent.id);
    if (running) return running;
    if (agent.conv.turns.length > 0 || agent.sessionFile === "") return Promise.resolve();
    const run = this.#readTranscriptInto(agent).finally(() => {
      this.#restoring.delete(agent.id);
    });
    this.#restoring.set(agent.id, run);
    return run;
  }

  async #readTranscriptInto(agent: Agent): Promise<void> {
    const file = agent.sessionFile;
    try {
      const { entries, torn } = await readTranscript(file);
      if (torn > 0) log.warn("skipped torn transcript lines", { file, torn });
      const turns = rehydrate(entries, { now: Date.now, newId: () => crypto.randomUUID() });
      if (turns.length === 0) return;
      // Belt and braces. `#ask` waits on this read precisely so this can no
      // longer happen -- but `install()` replacing a live turn list is bad
      // enough that the guard stays.
      if (agent.conv.turns.length > 0) return;
      agent.conv.install(turns);
      log.info("restored transcript", { conv: agent.id, file, turns: turns.length });
    } catch (e) {
      // A missing or unreadable session file is a session that cannot be shown,
      // not a host that stops working.
      log.warn("transcript restore failed", { file, err: String(e) });
    }
  }

  /* ---------------------------------------------------------- client events */

  #onHello(conn: Conn, channel: string, displaced: boolean): void {
    // A displaced predecessor never fires `onGone` (transport.ts), so counting
    // this one too would leave the client count permanently high and the 90s
    // orphan grace permanently unarmed.
    if (!displaced) this.pool.clientConnected();

    const agent = this.#active();
    if (!agent) {
      log.error("hello with no active conversation", { channel });
      return;
    }
    conn.send({
      t: "hello",
      version: PROTOCOL_VERSION,
      workdir: agent.conv.state.workdir,
      convId: agent.id,
    });
    conn.send(agent.snapshot());
    conn.send({ t: "sessions", entries: this.pool.list(), activeId: agent.sessionId });
    conn.send({ t: "models", models: this.catalog.availableModels });
    conn.send({ t: "commands", commands: this.#panelCmds() });
    log.info("client attached", { channel, conv: agent.id, displaced });
    // A panel connecting IS the panel asking for the session list, and sessions
    // pi wrote while this host was down are only findable by looking. The list
    // above went out first; a second one follows if the scan turns anything up.
    void this.rescan();
  }

  #onCommand(conn: Conn, cmd: ClientCmd): void {
    switch (cmd.t) {
      case "hello":
        return; // consumed by the transport before it gets here

      case "ask":
        void this.#ask(conn, cmd.text, cmd.images, cmd.id);
        return;

      case "abort": {
        // Ctrl+C applies to the ACTIVE conversation only
        // (docs/specs/multi-session.md).
        this.#active()?.send({ type: "abort" });
        this.#ack(conn, cmd.id, true);
        return;
      }

      case "command":
        this.#command(conn, cmd.line, cmd.id);
        return;

      case "attach_clipboard":
        void this.#attach(conn, cmd.id);
        return;

      case "attach_path":
        void this.#attachPath(conn, cmd.path, cmd.id);
        return;

      case "attach_sync":
        this.#staging.sync(cmd.draft);
        return;

      case "new":
        // Parks, never stops. The parked child keeps running and its turn
        // finishes in the background (pool.ts).
        this.pool.create();
        this.#ack(conn, cmd.id, true);
        return;

      case "resume": {
        try {
          const conv = this.pool.resume(cmd.sessionId) as Agent;
          this.#ack(conn, cmd.id, true);
          // The pool's own snapshot has already gone out and is EMPTY for a
          // session it had to build cold. The transcript read is asynchronous,
          // so it lands as a second snapshot a few milliseconds later.
          void this.#restore(conv);
        } catch (e) {
          this.broadcast({ t: "error", text: String(e) });
          this.#ack(conn, cmd.id, false, String(e));
        }
        return;
      }

      case "activate": {
        const ok = this.pool.activate(cmd.convId);
        if (!ok) this.broadcast({ t: "error", text: `no such conversation: ${cmd.convId}` });
        else void this.#restore(this.#active());
        this.#ack(conn, cmd.id, ok);
        return;
      }

      case "panel":
        if (cmd.open) void this.#usage.refresh();
        return;

      case "resync": {
        const agent = this.#active();
        if (agent) conn.send(agent.snapshot());
        this.#ack(conn, cmd.id, agent !== null);
        // Same reason as `hello`: a resync is the panel re-asking for
        // everything, and unchanged files make this nearly free.
        void this.rescan();
        return;
      }

      default: {
        // A command with no arm was dropped in SILENCE: `attach_path` shipped
        // in the union with no case here, so `ori image` staged a question that
        // could never be sent and no reply of any kind came back. The `never`
        // binding makes tsc the gate -- a new ClientCmd member stops narrowing
        // and the build breaks here rather than in the panel.
        const unhandled: never = cmd;
        log.warn("unhandled client command", { cmd: unhandled });
        return;
      }
    }
  }

  async #ask(conn: Conn, text: string, imageMarkers: number[], id?: string): Promise<void> {
    const agent = this.#active();
    if (!agent) {
      this.#ack(conn, id, false, "no active conversation");
      return;
    }

    // A question typed while this conversation is still reading its transcript
    // waits for the read. Otherwise the read loses -- it must refuse to install
    // over a live turn list -- and it loses PERMANENTLY, leaving that
    // conversation with no history for the rest of its life. Typically
    // microseconds; the file it waits on is one this host is already reading.
    await this.#restoring.get(agent.id);

    const refs: ImageRef[] = [];
    const payload: ImagePayload[] = [];
    for (const path of this.#staging.resolve(imageMarkers)) {
      const enc = await encodeImage(path);
      if (!enc.ok) {
        // Reported and skipped: a missing picture beats a refused question
        // (images.ts).
        this.broadcast({ t: "error", text: enc.error });
        continue;
      }
      refs.push({ path, mime: enc.mime, bytes: enc.bytes });
      payload.push({ type: "image", data: enc.data, mimeType: enc.mime });
    }
    // Cleared only now, because the question was ACCEPTED -- not merely typed.
    this.#staging.clear();

    agent.ask(text, refs, payload);
    this.#ack(conn, id, true);
  }

  #command(conn: Conn, line: string, id?: string): void {
    const agent = this.#active();
    if (!agent) {
      this.#ack(conn, id, false, "no active conversation");
      return;
    }
    const out = parseCommand(line, {
      warm: agent.conv.state.warm,
      models: this.catalog.availableModels,
      usable: this.catalog.usableModels,
      levels: this.catalog.effortScale(),
    });

    if (out.t === "error") {
      this.broadcast({ t: "error", text: out.message });
      this.#ack(conn, id, false, out.message);
      return;
    }
    if (out.t === "pass") {
      // Not a PANEL command, which does not make it nonsense: pi has slash
      // commands of its own and they arrive as ordinary prompt text.
      void this.#ask(conn, line, [], id);
      return;
    }
    this.#run(out.intent, agent);
    this.#ack(conn, id, true);
  }

  #run(intent: Intent, agent: Agent): void {
    switch (intent.t) {
      case "set_model":
        this.catalog.applyModelChoice(intent.provider, intent.id);
        if (agent.conv.state.warm) {
          // Warm: pi is authoritative, and the response is what moves the
          // panel's state (conversation.ts).
          agent.send({ type: "set_model", provider: intent.provider, modelId: intent.id });
        } else {
          // Cold: this IS the answer. It reaches pi as the next spawn's argv.
          agent.conv.patchState({
            provider: intent.provider,
            model: intent.id,
            effort: "",
            thinkingLevel: "",
            levels: [],
          });
        }
        return;

      case "set_effort":
        this.catalog.setEffort(intent.level);
        if (agent.conv.state.warm) agent.send({ type: "set_thinking_level", level: intent.level });
        // Shown immediately either way: `set_thinking_level` acks success for
        // every string, so the ack proves nothing and get_state corrects this.
        agent.conv.patchState({ effort: intent.level, thinkingLevel: intent.level });
        return;

      case "new":
        this.pool.create();
        return;

      case "compact":
        agent.send({ type: "compact" });
        return;

      case "name":
        agent.send({ type: "set_session_name", name: intent.name });
        return;

      case "export":
        agent.send({ type: "export_html" });
        return;

      case "restart":
        agent.killChild("/restart");
        return;
    }
  }

  async #attach(conn: Conn, id?: string): Promise<void> {
    const shot = await capture();
    if (shot.t === "none") {
      // Exit 3: an ordinary Ctrl+V of text. Silent by design -- the composer
      // pastes the text itself (images.ts).
      this.#ack(conn, id, true);
      return;
    }
    if (shot.t === "failed") {
      conn.send({ t: "attach_failed", why: shot.why });
      this.#ack(conn, id, false, shot.why);
      return;
    }
    const n = this.#staging.attach(shot.path);
    conn.send({ t: "attached", n, path: shot.path });
    this.#ack(conn, id, true);
  }

  /**
   * The same staging for a path the caller NAMES -- `ori image`, which has no
   * clipboard to read from.
   *
   * It encodes to VERIFY: a marker index handed out for a path that turns out
   * to be missing, empty, oversized or not an image would fail at `#ask` time
   * instead, long after the caller was told the picture was staged. The encode
   * is thrown away and redone at send time; that is 1.34 ms for 8 MB
   * (images.ts) against a wrong answer to "is this attachable".
   *
   * The reply carries `id` so the panel can tell a staged `ori image` picture
   * from a Ctrl+V one -- see protocol.ts.
   */
  async #attachPath(conn: Conn, path: string, id?: string): Promise<void> {
    const enc = await encodeImage(path);
    if (!enc.ok) {
      // `id` may be undefined; JSON.stringify drops the key, which is exactly
      // the "clipboard, uncorrelated" shape.
      conn.send({ t: "attach_failed", id, why: enc.error });
      this.#ack(conn, id, false, enc.error);
      return;
    }
    const n = this.#staging.attach(path);
    conn.send({ t: "attached", id, n, path });
    this.#ack(conn, id, true);
  }

  #ack(conn: Conn, id: string | undefined, ok: boolean, error?: string): void {
    if (id === undefined) return;
    conn.send(error === undefined ? { t: "ack", id, ok } : { t: "ack", id, ok, error });
  }
}

/* ------------------------------------------------------------------ *
 * entry point
 * ------------------------------------------------------------------ */

function defaultDbPath(home: string): string {
  const state = (Bun.env["XDG_STATE_HOME"] || `${home}/.local/state`) + "/ori-host";
  return `${state}/sessions.db`;
}

/**
 * SIGTERM is how systemd stops this unit, so it must do the whole job: close
 * the listener, unlink the socket file (a filesystem unix socket is NOT removed
 * on exit) and SIGTERM every pi child. Latched, because systemd sends TERM and
 * then KILL, and a second pass through `stop()` would double-close the store.
 */
function installSignals(host: Host): void {
  let stopping = false;
  const bye = (signal: string): void => {
    if (stopping) return;
    stopping = true;
    log.info("shutting down", { signal });
    void host
      .stop()
      .catch((e: unknown) => log.error("shutdown failed", { err: String(e) }))
      .finally(() => process.exit(0));
  };
  process.on("SIGTERM", () => bye("SIGTERM"));
  process.on("SIGINT", () => bye("SIGINT"));
}

// Wrapped in a function rather than written as a top-level await: Bun's
// bundler rejects TLA inside a conditional block, and `bun build --compile` is
// how this ships.
async function main(): Promise<void> {
  const host = new Host();
  installSignals(host);
  await host.start();
  log.info("ori-host up", { socket: host.socketPath, paths: defaultPaths() });
}

if (import.meta.main) {
  void main().catch((e: unknown) => {
    log.error("failed to start", { err: String(e) });
    process.exit(1);
  });
}
