/**
 * The pi command line. Pure functions -- no spawn, no fs, no clock.
 *
 * This is `ori-agent`'s build_command() (ori-agent:298-401) with its decisions
 * intact. Every flag below was argued for once and the argument is recorded
 * next to it; none of them are defaults anybody reached for.
 *
 * The one filesystem fact this file needs -- "does this prompt file exist" --
 * arrives through an injected `exists` predicate, so the whole module is
 * testable with no disk.
 */

/* ------------------------------------------------------------------ *
 * Settings that describe a PROCESS rather than a conversation.
 * Lifted verbatim from ori-agent's settings block.
 * ------------------------------------------------------------------ */

export const BINARY = "pi";

/**
 * Where the child runs: the repo that configures this machine, including the
 * shell Ori's face is drawn by. Measured cost of running here rather than in a
 * neutral directory: 3157 -> 5964 input tokens, i.e. ~2.8K of repo knowledge
 * out of a 131K window. Reported to the panel so its footer cannot name a
 * directory pi is not in.
 */
export const WORKDIR = "~/.dotfiles";

/**
 * Where shim-web sends its searches: the VPS, not a local instance.
 *
 * This was `http://127.0.0.1:11435` once, to save a round trip. That held only
 * while the local unit was running -- the moment ollama-shim.service stopped,
 * shim-web dialled a dead port with no timeout, pi never settled, and the panel
 * sat on "thinking" forever with nothing in any log. A default that fails CLOSED
 * is worse than a slower one that works.
 */
export const SHIM_URL = "https://ollama.ncym.uk";

/**
 * Prepended to the system prompt, in order. pi accepts a PATH here as well as
 * text -- and it does NOT expand CLAUDE.md's `@file` imports, so every file has
 * to be named. (Point it at a workspace whose CLAUDE.md is nothing but `@`
 * lines and it answers "I'm Claude, an AI coding assistant running inside pi";
 * that is how this was found.)
 */
export const PROMPT_FILES: readonly string[] = [
  "~/.config/assistant/soul.md",
  "~/.config/assistant/laptop.md",
  "~/.config/assistant/memory.md",
  // Who he is, as opposed to what this machine is. Written by the `memory`
  // tool, same as memory.md -- see the extension for why the two are split.
  "~/.config/assistant/user.md",
];

/**
 * Extensions, opted into by path. `-ne` disables discovery and each entry here
 * is loaded back explicitly, which leaves the global set in
 * `~/.pi/agent/extensions/` alone so `pi` in a terminal is unchanged.
 */
export const EXTENSIONS: readonly string[] = [
  // intent, not a restatement of the arguments -- the panel's tool card shows
  // args.description, so it shows the why.
  "~/Development/Personal/my-pi/extensions/tool-descriptions.ts",

  // web_search / web_fetch. The search runs on the shim (that is where the
  // Brave and Ollama keys live); the fetch runs on this laptop, so Ori can read
  // 127.0.0.1 and the LAN, which a VPS cannot. pi makes the call, so pi emits
  // tool_execution_start, so the panel can SHOW the search -- a shim-side loop
  // is invisible to the client by construction.
  "~/Development/Personal/my-pi/extensions/shim-web.ts",

  // Bounded, agent-owned memory: memory.md and user.md, with a cap that REFUSES
  // an overflowing write and hands back the current entries, so consolidation
  // happens in the same turn instead of never.
  "~/Development/Personal/my-pi/extensions/memory.ts",

  // Delegation. Each subagent is a separate pi process, so its context is
  // genuinely isolated -- the parent gets the report and none of the reading
  // that produced it.
  "~/Development/Personal/my-pi/extensions/subagent",

  // One free-text note the agent keeps for itself, nudged every 8% of context,
  // asked for properly at 60%. Compaction keeps the note and the recent turns
  // and drops the rest -- no summariser call, no cold re-read.
  "~/Development/Personal/my-pi/extensions/session-note.ts",

  // Text-to-speech. kokoro-npu streams to the speakers itself; the tool spawns
  // it detached and returns the pid, so a spoken reply never blocks the turn.
  "~/Development/Personal/my-pi/extensions/speak.ts",
];

export const DEFAULT_PROVIDER = "ollama";
export const DEFAULT_MODEL = "glm-5.3-flash";

/* ------------------------------------------------------------------ */

export interface PiSpawnConfig {
  provider?: string;
  model?: string;
  /** Thinking level. Empty/absent means "provider default" -- omit `--thinking`. */
  effort?: string;
  /**
   * Exact project session id. `--session-id` is idempotent ("use exact project
   * session ID, creating it if missing"), which is what multi-session needs:
   * one conversation -> one child -> one session id -> one row. `--session`
   * (a path) is not used here.
   */
  sessionId?: string;
  /**
   * Per-child file that a bash call in flight watches for "wrap up now".
   * Absent means the detach side channel is simply off for this child, which
   * is the correct behaviour when the file could not be created.
   */
  detachPath?: string;

  workdir?: string;
  binary?: string;
  promptFiles?: readonly string[];
  extensions?: readonly string[];

  /** Home directory used for `~` expansion. Injected so tests need no $HOME. */
  home: string;
  /** Existence check for prompt files. Injected so this module never touches disk. */
  exists: (path: string) => boolean;
}

/**
 * Expand a leading `~`. Only `~` and `~/...` -- `~user` is not a form anything
 * in this project uses, and silently mangling it would be worse than leaving it.
 */
export function expandTilde(p: string, home: string): string {
  if (p === "~") return home;
  if (p.startsWith("~/")) return home + p.slice(1);
  return p;
}

/**
 * The pi argv, `argv[0]` included.
 *
 * Produces:
 *   pi --mode rpc -ne -nc --provider P --model M
 *      [--thinking L] [--session-id ID]
 *      --append-system-prompt F (xN)  -e EXT (xN)
 */
export function buildArgv(cfg: PiSpawnConfig): string[] {
  const argv: string[] = [
    cfg.binary ?? BINARY,
    "--mode",
    "rpc",

    // No extension discovery. The recorded reason (pi's bundled
    // openai-codex-usage.ts calling assertActive() on a UI that does not exist
    // outside a TTY) is no longer true of the installed pi -- but a second,
    // live reason is: discovery loads ~/.pi/agent/extensions/pi-web-access,
    // which registers a `web_search` tool that COLLIDES with the shim-web.ts
    // loaded by hand below. pi does not warn and carry on, it refuses to start:
    //   Error: Failed to load extension ".../pi-web-access/index.ts":
    //   Tool "web_search" conflicts with .../my-pi/extensions/shim-web.ts
    // Isolated both ways. Drop `-ne` and you must drop shim-web too.
    "-ne",

    // No AGENTS.md / CLAUDE.md discovery. WORKDIR is ~/.dotfiles, so pi was
    // prepending all 14.6KB of that repo's CLAUDE.md to every spawn: measured
    // at 4490 tokens, 45% of a 10040-token cold start, on a child that gets
    // killed after ten minutes of silence. It is the repo's DEVELOPER
    // documentation; Ori can read it deliberately like any other file.
    "-nc",

    "--provider",
    cfg.provider || DEFAULT_PROVIDER,
    "--model",
    cfg.model || DEFAULT_MODEL,
  ];

  if (cfg.effort) argv.push("--thinking", cfg.effort);
  if (cfg.sessionId) argv.push("--session-id", cfg.sessionId);

  for (const f of cfg.promptFiles ?? PROMPT_FILES) {
    const p = expandTilde(f, cfg.home);
    // THE TRAP, and the reason this function needs `exists` at all: pi accepts
    // either a path or literal prompt text here, and tells them apart with a
    // bare existsSync() that does NOT expand `~`. So an unexpanded or missing
    // path is silently prepended to the system prompt as TEXT -- the file's
    // contents never reach the model and nothing anywhere says so. Expand
    // ourselves, and pass nothing at all rather than a path that does not
    // resolve.
    if (!cfg.exists(p)) continue;
    argv.push("--append-system-prompt", p);
  }

  for (const e of cfg.extensions ?? EXTENSIONS) {
    // Expanded here rather than left for the login shell, because these are
    // quoted on the way into `sh -lc` (see buildShellCommand) and a quoted `~`
    // does not expand. NOT existence-filtered: a missing extension makes pi
    // refuse to start with a named error, which is the right failure -- silently
    // running without shim-web or memory would be worse than not running.
    argv.push("-e", expandTilde(e, cfg.home));
  }

  return argv;
}

/**
 * Environment additions for the child. Merged over the host's own environment
 * by the caller; nothing here is a secret (OLLAMA_API_KEY comes from
 * ~/.config/fish/conf.d/secrets.fish via the login shell, and deliberately
 * never touches a unit file or a command line).
 */
export function buildEnv(cfg: PiSpawnConfig): Record<string, string> {
  const env: Record<string, string> = { SHIM_URL: SHIM_URL };
  // Read by tool-descriptions.ts, which arms NOTHING when the variable is
  // absent. So `pi` in a terminal is untouched, and so is a spawn whose detach
  // file could not be created.
  if (cfg.detachPath) env["ORI_DETACH_PATH"] = cfg.detachPath;
  return env;
}

/** The directory the child runs in, `~` already expanded -- it is quoted on the
 *  way into `sh -lc`, so the shell will not expand it for us. */
export function buildWorkdir(cfg: PiSpawnConfig): string {
  return expandTilde(cfg.workdir ?? WORKDIR, cfg.home);
}

/** POSIX single-quote quoting. Safe for session ids (ISO timestamps carry `:`)
 *  and for any path with a space in it. */
export function shQuote(s: string): string {
  return "'" + s.replaceAll("'", `'\\''`) + "'";
}

/**
 * Wrap the pi argv for a login shell.
 *
 * `sh -lc` stays for the reason it was chosen: a login shell is what puts
 * ~/.bun/bin on PATH (so `pi` is found at all) and OLLAMA_API_KEY in the
 * environment (so something answers). Measured from a clean systemd-user
 * environment, neither exists without it.
 *
 * `exec` stays because it makes sh REPLACE itself with pi. Two things depend on
 * that: pi's stdin is the pipe rather than the shell's, and the pid we hold is
 * pi's -- which is what lets kill() reach the agent, and what makes the pid in
 * the detach record something a subagent can compare itself against.
 */
export function buildShellCommand(argv: readonly string[], workdir: string): string[] {
  const cd = "cd " + shQuote(workdir) + " && exec ";
  return ["sh", "-lc", cd + argv.map(shQuote).join(" ")];
}
