/**
 * The host <-> panel wire contract. NDJSON over a unix socket.
 *
 * This file has NO imports and NO side effects. It is the one thing both ends
 * agree on, and the only file every other module is allowed to depend on.
 *
 * Framing: `JSON.stringify(obj) + "\n"`, both directions. JSON.stringify
 * escapes newlines, so a record never contains a bare \n. Quickshell splits on
 * "\n" only (SplitParser), which is also what pi's RPC mode requires -- node's
 * readline is NOT protocol-compliant here because it additionally splits on
 * U+2028/U+2029, both valid inside a JSON string.
 *
 * Two design decisions worth defending, because the old code did the opposite
 * and paid for it:
 *
 * 1. Everything is addressed by a stable string id, never by row index. The old
 *    panel kept five parallel maps (toolLog, turnCost, ...) keyed on the index
 *    into a ListModel, and had to re-key all of them (`shiftRowKeys`) whenever a
 *    steer inserted a row mid-list. Ids delete that whole class of bug.
 *
 * 2. Deltas are APPENDS, not replacements. `turn_delta` carries only the new
 *    characters. The panel concatenates. Note that pi's own
 *    `tool_execution_update.partialResult` is CUMULATIVE, so the host must diff
 *    it before emitting -- otherwise the panel renders the prefix N times.
 */

export const PROTOCOL_VERSION = 1;

/* ------------------------------------------------------------------ *
 * Conversation content -- what the panel draws
 * ------------------------------------------------------------------ */

export type Role = "user" | "assistant";

/** Delivery receipt for a user turn. The panel renders this as a tick. */
export const enum Delivery {
  /** Queued locally; the child is not up yet. */
  Queued = 0,
  /** Written to the socket. */
  Sent = 1,
  /** The model has demonstrably read it (a token came back after it). */
  Read = 2,
}

export interface ImageRef {
  /** Local file path, for the panel to display. Never the base64 payload -- the
   *  panel must never hold a multi-megabyte string. */
  path: string;
  mime: string;
  bytes: number;
}

export type ToolState = "running" | "ok" | "error";

export interface ToolCall {
  id: string;
  name: string;
  /** One-line human summary, e.g. `read foo.ts`. Computed host-side. */
  summary: string;
  /** Full argument text, for the expanded view. */
  raw: string;
  state: ToolState;
  /** Result text once finished. Truncated host-side; the panel shows it as-is. */
  result?: string;
  /** Character offset into the owning turn's `text` where this call appeared,
   *  so the panel can interleave tool rows with prose in the right order. */
  at: number;
}

export interface TurnCost {
  input: number;
  output: number;
  seconds: number;
  tokensPerSecond: number;
}

/** One row in the panel's transcript ListView. */
export interface Turn {
  id: string;
  role: Role;
  text: string;
  thinking: string;
  tools: ToolCall[];
  images: ImageRef[];
  /** True while this turn is the live sink for deltas. */
  pending: boolean;
  /** Only meaningful for role === "user". */
  delivery: Delivery;
  cost?: TurnCost;
  /** Epoch ms when the turn stopped changing. */
  settledAt?: number;
}

/* ------------------------------------------------------------------ *
 * Ambient state -- one authoritative copy, held by the host
 * ------------------------------------------------------------------ */

export interface SessionState {
  /** The panel NEVER derives this. */
  busy: boolean;
  compacting: boolean;
  /** Human phase text while compacting, e.g. "writing the summary". */
  compactPhase: string;
  /** True once a pi child is up and has answered the probe burst. */
  warm: boolean;

  provider: string;
  model: string;
  /** Pinned effort, e.g. "medium". Empty string means "provider default". */
  effort: string;
  /** Effective thinking level as pi reports it -- may differ from `effort`
   *  because pi clamps silently and acks success for every string. Only
   *  get_state / thinking_level_changed are trustworthy. */
  thinkingLevel: string;
  /** Efforts offered for the CURRENT model, already filtered. */
  levels: string[];

  sessionId: string;
  sessionFile: string;
  sessionName: string;
  /** cwd the child runs in. */
  workdir: string;
}

export interface Usage {
  input: number;
  output: number;
  total: number;
  contextWindow: number;
  /** True when `total` is a post-compaction estimate rather than a real
   *  reading, so a stale larger figure arriving later must be ignored. */
  estimated: boolean;
}

export type BgKind = "job" | "monitor" | "agent" | "speak";

export interface BgJob {
  pid: number;
  kind: BgKind;
  label: string;
  name: string;
  /** Epoch ms. */
  since: number;
  /** Live activity line for subagents, from the pi subagent registry. */
  activity?: string;
}

export interface ModelChoice {
  provider: string;
  id: string;
  name: string;
}

export interface SlashCommand {
  name: string;
  description: string;
  source: "extension" | "prompt" | "skill" | "panel";
  /** Closed argument set, when there is one (e.g. /effort). */
  values?: string[];
}

/** A row in the session picker. */
export interface SessionEntry {
  id: string;
  file: string;
  label: string;
  /** Epoch ms of last activity. */
  at: number;
  turns: number;
  /** In memory right now (parked or active) rather than on disk only. */
  live: boolean;
  /** Mid-turn. A parked session can be busy -- that is the point. */
  busy: boolean;
}

/* ------------------------------------------------------------------ *
 * host -> panel
 * ------------------------------------------------------------------ */

export type HostEvent =
  /** First frame on every connection. */
  | { t: "hello"; version: number; workdir: string; convId: string }
  /** Full state of the active conversation. Sent on connect, on activate, and
   *  after any resync. The panel replaces everything it holds. */
  | { t: "snapshot"; convId: string; turns: Turn[]; state: SessionState; usage: Usage; bg: BgJob[] }
  /** A turn was appended, or INSERTED at `index` when a steer split the seam. */
  | { t: "turn_add"; convId: string; turn: Turn; index?: number }
  /** Append-only growth of the live turn. */
  | { t: "turn_delta"; convId: string; turnId: string; field: "text" | "thinking"; delta: string }
  /** Any other field changing on an existing turn. */
  | { t: "turn_patch"; convId: string; turnId: string; patch: Partial<Turn> }
  /** A turn was removed -- only happens when a steer drops an empty row. */
  | { t: "turn_drop"; convId: string; turnId: string }
  | { t: "tool_add"; convId: string; turnId: string; tool: ToolCall }
  | { t: "tool_patch"; convId: string; turnId: string; toolId: string; patch: Partial<ToolCall> }

  | { t: "state"; convId: string; patch: Partial<SessionState> }
  | { t: "usage"; convId: string; usage: Usage }
  | { t: "bg"; convId: string; jobs: BgJob[] }

  /** The session list, including parked-and-busy ones. Drives the picker. */
  | { t: "sessions"; entries: SessionEntry[]; activeId: string }
  | { t: "models"; models: ModelChoice[] }
  | { t: "commands"; commands: SlashCommand[] }

  /** Transient success/progress text. Distinct from `error`, which pins the
   *  panel border to the busy accent -- writing a success message into `error`
   *  was a real bug. */
  | { t: "notice"; text: string }
  | { t: "error"; text: string }

  /** An image was captured from the clipboard and is ready to attach. `n` is
   *  the 1-based marker index the composer inserts as `[Image n]`. */
  | { t: "attached"; n: number; path: string }
  | { t: "attach_failed"; why: string }

  /** Correlated reply to a ClientCmd that carried an `id`. */
  | { t: "ack"; id: string; ok: boolean; error?: string };

/* ------------------------------------------------------------------ *
 * panel -> host
 * ------------------------------------------------------------------ */

export type ClientCmd =
  /** Sent once on connect. `channel` identifies this UI so a reconnect adopts
   *  the same conversations instead of creating new ones. */
  | { t: "hello"; channel: string; version: number }

  /** Send a message. The HOST decides prompt-vs-steer from its own `busy` --
   *  the panel does not know and must not guess. `images` are marker indices
   *  previously handed out by `attached`. */
  | { t: "ask"; id?: string; text: string; images: number[] }
  | { t: "abort"; id?: string }

  /** A raw composer line beginning with "/". The host owns parsing, including
   *  /model and /effort, which must work with NO child running. */
  | { t: "command"; id?: string; line: string }

  /** Capture an image from the Wayland clipboard. Replies with `attached` or
   *  `attach_failed`. */
  | { t: "attach_clipboard"; id?: string }
  /** Drop staged attachments whose `[Image n]` marker is no longer in `draft`. */
  | { t: "attach_sync"; draft: string }

  /** Multi-session. `new` and `resume` PARK the current conversation -- they
   *  never stop a running turn. See docs/specs/multi-session.md. */
  | { t: "new"; id?: string }
  | { t: "resume"; id?: string; sessionId: string }
  | { t: "activate"; id?: string; convId: string }

  /** Panel visibility, so the host can own the unread mark. */
  | { t: "panel"; open: boolean }

  /** Force a fresh `snapshot`. */
  | { t: "resync"; id?: string };

/* ------------------------------------------------------------------ *
 * Framing helpers -- the only behaviour in this file
 * ------------------------------------------------------------------ */

export function encode(msg: HostEvent | ClientCmd): string {
  return JSON.stringify(msg) + "\n";
}

/**
 * Split a byte-chunk stream into NDJSON records. Returns parsed values and the
 * leftover partial line, which the caller carries into the next chunk.
 *
 * Malformed lines are DROPPED, not thrown: a single torn record must never take
 * down a long-lived connection. The caller logs `bad`.
 */
export function decodeLines(buffered: string): {
  msgs: unknown[];
  bad: string[];
  rest: string;
} {
  const msgs: unknown[] = [];
  const bad: string[] = [];
  const parts = buffered.split("\n");
  const rest = parts.pop() ?? "";
  for (const line of parts) {
    if (line === "") continue;
    try {
      msgs.push(JSON.parse(line));
    } catch {
      bad.push(line);
    }
  }
  return { msgs, bad, rest };
}
