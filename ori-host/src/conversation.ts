/**
 * conversation.ts -- pi events in, HostEvents out.
 *
 * The whole point of the rewrite lives in this file: ONE parser for the pi wire
 * protocol, in one language, holding ONE copy of the conversation. The Python
 * broker and PiSession.qml each parsed the same frames and each kept their own
 * `busy`, their own idea of which row was streaming, and their own turn list.
 * Every hard bug traced back to those two copies drifting.
 *
 * It is a pure state machine. No socket, no child process, no filesystem, no
 * timers. Everything that would be a side effect -- the clock, id generation,
 * outbound pi commands, the get_entries payload -- goes through `ConversationDeps`
 * so a test can drive it deterministically.
 *
 * Two structural facts that delete whole classes of old bug:
 *
 * 1. Turns are addressed by a stable id, never by index. The old panel keyed
 *    five parallel maps (`toolLog`, `turnCost`, ...) on the row index and had to
 *    `shiftRowKeys()` on every steer insert. Here a seam insert is a splice and
 *    nothing needs re-keying, because nothing else refers to position.
 * 2. `liveId` is EXPLICIT -- the assistant turn the answer in flight is being
 *    written into. Deriving it as "the newest assistant turn" is what welded a
 *    redirected answer onto the end of the interrupted one: after a steer the
 *    newest rows are [answer][question] and the deltas still belong to the one
 *    above.
 */

import {
  Delivery,
  type BgJob,
  type BgKind,
  type HostEvent,
  type ImageRef,
  type ModelChoice,
  type SessionState,
  type SlashCommand,
  type ToolCall,
  type Turn,
  type TurnCost,
  type Usage,
} from "./protocol";

/* ------------------------------------------------------------------ *
 * pi wire shapes
 *
 * Transcribed from pi's own declarations, NOT invented. Sources:
 *   @earendil-works/pi-agent-core/dist/types.d.ts            (AgentEvent,
 *                                                             AssistantMessageEvent
 *                                                             via pi-ai)
 *   @earendil-works/pi-coding-agent/dist/core/agent-session.d.ts
 *                                                            (AgentSessionEvent)
 *   @earendil-works/pi-coding-agent/dist/modes/json-event.d.ts
 *                                                            (JsonAgentSessionEvent)
 *   @earendil-works/pi-coding-agent/dist/modes/rpc/rpc-types.d.ts
 *                                                            (RpcResponse)
 *   @earendil-works/pi-ai/dist/types.d.ts                    (Usage, StopReason,
 *                                                             AssistantMessage)
 *
 * They are copied rather than deep-imported because ori-host has ZERO npm
 * dependencies -- pi is a global install, not a package.json entry, so
 * `import type ... from "@earendil-works/..."` does not resolve here. Every arm
 * is a structural WIDENING of pi's own (same field names, looser types), so a
 * real `JsonAgentSessionEvent` / `RpcResponse` is assignable to these. Fields
 * this file does not read are omitted; the arms it does not read are kept as
 * bare `{ type }` so the union stays exhaustively discriminated.
 * ------------------------------------------------------------------ */

/** pi-ai `Usage`. `totalTokens` is the field, not `total`. */
export interface PiUsage {
  input: number;
  output: number;
  totalTokens: number;
}

/** One block of `AssistantMessage.content` / `UserMessage.content`. */
export interface PiContentBlock {
  type?: string;
  text?: string;
}

/** pi-ai `Message` plus pi-coding-agent's `CustomMessage`, widened. */
export interface PiMessage {
  role: string;
  content?: string | PiContentBlock[];
  stopReason?: string;
  errorMessage?: string;
  /** CustomMessage only -- `bg_process_done` is the one this file reads. */
  customType?: string;
  /** `unknown` and not `Record<string, unknown>`, because that is exactly how
   *  pi declares it (`CustomMessage<T = unknown>`) and a narrower copy would
   *  reject pi's own type. Read through `field()`. */
  details?: unknown;
}

/** pi-agent-core `AgentToolResult`, widened. */
export interface PiToolResult {
  content?: PiContentBlock[];
  details?: unknown;
}

/** The `AssistantMessageEvent` arms that survive `toJsonEvent()`. */
export type PiAssistantMessageEvent =
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | {
      type:
        | "start"
        | "text_start"
        | "text_end"
        | "thinking_start"
        | "thinking_end"
        | "toolcall_start"
        | "toolcall_delta"
        | "toolcall_end"
        | "done"
        | "error";
    };

export type PiEvent =
  /** json-event.d.ts strips the cumulative `message` snapshot from this one;
   *  usage rides along and arrives even on updates carrying nothing else. */
  | { type: "message_update"; usage?: PiUsage; assistantMessageEvent?: PiAssistantMessageEvent }
  | { type: "message_start"; message?: PiMessage }
  | { type: "message_end"; message?: PiMessage }
  | { type: "tool_execution_start"; toolCallId: string; toolName: string; args?: unknown }
  | { type: "tool_execution_update"; toolCallId: string; partialResult?: PiToolResult }
  | { type: "tool_execution_end"; toolCallId: string; result?: PiToolResult; isError?: boolean }
  | { type: "agent_settled" }
  | { type: "thinking_level_changed"; level?: string }
  | { type: "compaction_start" }
  | {
      type: "compaction_end";
      result?: { estimatedTokensAfter?: number };
      aborted?: boolean;
      errorMessage?: string;
    }
  | { type: "summarization_retry_scheduled"; attempt?: number; maxAttempts?: number; delayMs?: number }
  | { type: "summarization_retry_attempt_start" }
  | { type: "summarization_retry_finished" }
  | {
      type:
        | "agent_start"
        | "agent_end"
        | "turn_start"
        | "turn_end"
        | "queue_update"
        | "entry_appended"
        | "session_info_changed"
        | "auto_retry_start"
        | "auto_retry_end"
        | "bash_execution_update";
    };

/** RpcResponse, widened. The `success: false` arm carries `error` and any
 *  `command` string, so `command` cannot be a literal union here. */
export interface PiResponse {
  id?: string | number;
  type: "response";
  command: string;
  success?: boolean;
  error?: string;
  data?: unknown;
}

/** RpcCommand, widened to what an outbound `send` needs to carry. */
export type PiCommand = { type: string; [key: string]: unknown };

/* ------------------------------------------------------------------ *
 * measured constants
 * ------------------------------------------------------------------ */

/**
 * A gap between deltas wider than this is a tool call or a stall, not
 * generation, so it does not count toward tok/s. Measured (PiSession.qml:781):
 * the widest gap between deltas mid-answer is well under a second, and the
 * narrowest tool call is comfortably over two.
 */
const GEN_GAP_CAP_MS = 2000;

/** Below this there is not enough generation time for a tok/s figure to mean
 *  anything -- the first delta of a turn has no predecessor to measure against. */
const GEN_MIN_MS = 400;

/** Tool output is an excerpt in the panel; the full text is in the session file.
 *  The TAIL is kept, because the case that overflows is a streaming bash log and
 *  its newest lines are the ones being watched. Exported so rehydrate.ts crops a
 *  restored result to the same size a live one gets -- two rules would mean a
 *  turn changing length when you reopened it. */
export const TOOL_RESULT_CAP = 4000;

/* ------------------------------------------------------------------ *
 * injected side effects
 * ------------------------------------------------------------------ */

export interface ConversationDeps {
  /** Wall clock. Injected so a test can bill a turn without sleeping. */
  now(): number;
  /** Stable turn/tool ids. */
  newId(): string;
  /**
   * Outbound pi RPC. The conversation is the only thing that knows WHEN a
   * reading became stale, so it chases its own: stats after a settle, state
   * after a set_model. Default is a no-op so the module stands alone.
   */
  send(cmd: PiCommand): void;
  /** `get_entries` payload. Transcript restore is store.ts's job, not this
   *  file's -- this hook only hands the entries over. */
  onEntries(entries: unknown[], leafId: string | null): void;
}

const defaultDeps: ConversationDeps = {
  now: () => Date.now(),
  newId: () => crypto.randomUUID(),
  send: () => {},
  onEntries: () => {},
};

export function emptyState(workdir = ""): SessionState {
  return {
    busy: false,
    compacting: false,
    compactPhase: "",
    warm: false,
    provider: "",
    model: "",
    effort: "",
    thinkingLevel: "",
    levels: [],
    sessionId: "",
    sessionFile: "",
    sessionName: "",
    workdir,
  };
}

export function emptyUsage(): Usage {
  return { input: 0, output: 0, total: 0, contextWindow: 0, estimated: false };
}

/* ------------------------------------------------------------------ *
 * argument summarising -- PiSession.qml:3232-3259
 * ------------------------------------------------------------------ */

function pick(args: unknown, keys: string[]): string {
  if (!args || typeof args !== "object") return "";
  const o = args as Record<string, unknown>;
  for (const k of keys) {
    const v = o[k];
    if (typeof v === "string" && v !== "") return v;
  }
  return "";
}

/**
 * "What is it doing", one line. A description the agent wrote for this call
 * beats any mechanical summary -- that is the whole point of tools that carry
 * one.
 */
export function summarizeArgs(args: unknown): string {
  const v = pick(args, ["description", "command", "file_path", "path", "pattern", "query"]);
  const line = v.split("\n")[0] ?? "";
  return line.length > 70 ? line.slice(0, 70) + "…" : line;
}

/**
 * "What did it actually run" -- the command, the path, the pattern. Never falls
 * back to the description: a row that prints the same sentence twice is worse
 * than a row that prints it once. Not truncated; the delegate that draws it
 * knows how much room it has.
 */
export function rawArgs(args: unknown): string {
  return pick(args, ["command", "file_path", "path", "pattern", "query"]).replace(/\s+$/, "");
}

/** Flatten a pi message's content to text. Content is either a bare string or a
 *  block list, and only the text blocks are the message. */
export function flattenContent(content: string | PiContentBlock[] | undefined): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let out = "";
  for (const b of content) if (b && b.type === "text" && typeof b.text === "string") out += b.text;
  return out;
}

export function tail(s: string, cap: number): string {
  return s.length <= cap ? s : "…" + s.slice(s.length - cap);
}

/* ------------------------------------------------------------------ *
 * Conversation
 * ------------------------------------------------------------------ */

export class Conversation {
  readonly convId: string;

  private readonly emit: (e: HostEvent) => void;
  private readonly deps: ConversationDeps;

  private readonly turnList: Turn[] = [];
  private readonly byId = new Map<string, Turn>();

  /** The assistant turn the answer in flight is written into. See the header. */
  private liveId: string | null = null;

  /**
   * EVERY steer that has gone out and not yet been echoed back, in the order it
   * was sent. A single slot was tried and it restored the welding bug in full:
   * two steers 1.5s apart, the second overwrote the slot, pi echoed the first,
   * the match failed, and the first redirect welded onto the tail of the
   * interrupted answer (PiSession.qml:1075-1091).
   *
   * Each entry carries the id of the user turn it created. The old code stashed
   * an INDEX and had to abandon it -- an index goes stale the moment the seam
   * drops a row -- and fell back to searching the transcript for the text, which
   * resolves two identical outstanding steers to the same row. An id cannot go
   * stale, which is the whole point of the id-addressed model.
   */
  private steerQueue: Array<{ text: string; turnId: string }> = [];

  /** Read receipts are inferred, so this gates the scan -- markRead() would
   *  otherwise run per token. */
  private awaitingRead = false;

  private st: SessionState;
  private usg: Usage = emptyUsage();

  /** The reading to distrust while an estimate stands: the pre-compact total.
   *  A stats answer at or above it is the old number arriving late. */
  private staleAbove = 0;

  private compactStartedAt = 0;
  private compactBeforeTokens = 0;

  /** Nothing in the protocol timestamps anything, so the clock is ours. */
  private turnStartedAt = 0;
  private outputBase = 0;
  /** Milliseconds spent actually GENERATING, which is not how long the turn
   *  took: a turn that ran `bash sleep 9` then wrote fifty tokens took ten
   *  seconds and generated for one. Gaps are summed, not the span. */
  private genMs = 0;
  private lastAppendAt = 0;

  /** toolCallId -> the turn and tool it belongs to, plus the result text already
   *  emitted. pi's `partialResult` is CUMULATIVE, so the last emission is what
   *  the diff is taken against. */
  private readonly openTools = new Map<string, { turnId: string; sent: string }>();

  /** The last authoritative text length at the start of the current LLM round,
   *  so `message_end` can reconcile only ITS round. A tool-using turn emits
   *  several message_end frames, each carrying only that round's message. */
  private roundBase = 0;

  private readonly bgJobs = new Map<number, BgJob>();

  constructor(convId: string, emit: (e: HostEvent) => void, deps: Partial<ConversationDeps> = {}) {
    this.convId = convId;
    this.emit = emit;
    this.deps = { ...defaultDeps, ...deps };
    this.st = emptyState();
  }

  /* ---------------------------------------------------------------- *
   * reading
   * ---------------------------------------------------------------- */

  get turns(): readonly Turn[] {
    return this.turnList;
  }

  get state(): SessionState {
    return { ...this.st, levels: [...this.st.levels] };
  }

  get usage(): Usage {
    return { ...this.usg };
  }

  get bg(): BgJob[] {
    return [...this.bgJobs.values()];
  }

  /**
   * Everything the panel needs to draw this conversation from nothing.
   *
   * `thinking` is carried for the PENDING turn only -- see cloneForSnapshot.
   */
  snapshot(): HostEvent {
    return {
      t: "snapshot",
      convId: this.convId,
      turns: this.turnList.map(cloneForSnapshot),
      state: this.state,
      usage: this.usage,
      bg: this.bg,
    };
  }

  /**
   * Replace the whole transcript with one rebuilt from a session file
   * (rehydrate.ts), and announce it as ONE snapshot.
   *
   * Takes ownership of `turns` -- they were just built for this and nothing else
   * holds them; `snapshot()` clones on the way to the wire.
   *
   * The reset is the point. A conversation restored from disk has nothing in
   * flight, so every piece of live state has to go with the old turn list or the
   * next question inherits it: a stale `liveId` would send the answer into a row
   * that no longer exists, a leftover steer would split the wrong turn, and a
   * `busy` left over from the conversation this object used to be would leave the
   * composer refusing to send.
   */
  install(turns: Turn[]): void {
    this.turnList.length = 0;
    this.byId.clear();
    for (const t of turns) {
      this.turnList.push(t);
      this.byId.set(t.id, t);
    }

    this.liveId = null;
    this.steerQueue = [];
    this.openTools.clear();
    this.awaitingRead = false;
    this.roundBase = 0;
    this.turnStartedAt = 0;
    this.genMs = 0;
    this.lastAppendAt = 0;
    // Written straight in rather than through patchState: the snapshot below is
    // the announcement, and a `state` event carrying the same three fields
    // immediately before it is noise the panel would have to reconcile.
    this.st = { ...this.st, busy: false, compacting: false, compactPhase: "" };

    this.emit(this.snapshot());
  }

  /* ---------------------------------------------------------------- *
   * driving from the panel side
   * ---------------------------------------------------------------- */

  /**
   * The user sent something. Returns whether it must go out as a `steer` rather
   * than a `prompt` -- the HOST decides that from its own `busy`, because the
   * panel does not know and must not guess.
   *
   * ONLY THE QUESTION IS APPENDED on the steer path. The assistant turn is not
   * touched and no new one is opened, because at this instant nothing has
   * changed about the answer in flight: pi has taken the steer and is still
   * writing the OLD one. The split happens at the seam, on the echo.
   */
  ask(text: string, images: ImageRef[] = []): { turnId: string; steer: boolean } {
    const steer = this.st.busy;
    const u = this.addTurn("user", { text, images, delivery: Delivery.Queued });
    this.awaitingRead = true;

    if (steer) {
      this.steerQueue = [...this.steerQueue, { text, turnId: u.id }];
      return { turnId: u.id, steer: true };
    }

    // The head of a request is the catch-all for a steer that outlived its turn:
    // an abort clears `busy` without settling, so a leftover entry would split
    // the NEXT question's turn instead (PiSession.qml:1246-1252).
    this.steerQueue = [];
    this.startClock();
    this.patchState({ busy: true });
    // The assistant turn exists before a single token arrives, so the view has
    // something to stream into and the conversation never visibly jumps.
    const a = this.addTurn("assistant", { pending: true });
    this.liveId = a.id;
    this.roundBase = 0;
    return { turnId: u.id, steer: false };
  }

  /** The message reached the socket. Queued -> Sent. */
  markSent(turnId: string): void {
    const t = this.byId.get(turnId);
    if (!t || t.role !== "user" || t.delivery >= Delivery.Sent) return;
    t.delivery = Delivery.Sent;
    this.emit({ t: "turn_patch", convId: this.convId, turnId, patch: { delivery: Delivery.Sent } });
  }

  /** Ambient state the pool owns rather than the wire -- `warm`, `workdir`. */
  patchState(patch: Partial<SessionState>): void {
    const st = this.st as unknown as Record<string, unknown>;
    let changed = false;
    for (const [k, v] of Object.entries(patch)) {
      if (st[k] === v) continue;
      st[k] = v;
      changed = true;
    }
    // `levels` is an array, so the identity test above always calls it changed;
    // that is harmless and cheaper than a deep compare.
    if (!changed) return;
    this.emit({ t: "state", convId: this.convId, patch });
  }

  /* ---------------------------------------------------------------- *
   * pi events
   * ---------------------------------------------------------------- */

  handleEvent(ev: PiEvent): void {
    switch (ev.type) {
      case "message_update": {
        // Usage rides along with the deltas -- and arrives on updates carrying
        // nothing else -- so it is read before the bail-out below.
        if (ev.usage) this.applyUsage(ev.usage);
        const e = ev.assistantMessageEvent;
        if (!e) return;
        // Reasoning and answer are SEPARATE delta streams. Keeping them apart
        // is what lets the panel show thinking as a loading state and then
        // replace it with the answer, instead of running the two together.
        if (e.type === "thinking_delta") this.grow("thinking", e.delta);
        else if (e.type === "text_delta") this.grow("text", e.delta);
        return;
      }

      case "message_start": {
        // Only an assistant message opens a round worth reconciling; the user
        // echo gets one of these too, immediately after the seam.
        if (ev.message?.role !== "assistant") return;
        const live = this.live();
        this.roundBase = live ? live.text.length : 0;
        return;
      }

      case "message_end":
        this.onMessageEnd(ev.message);
        return;

      case "tool_execution_start": {
        // A turn that reaches for a tool before saying a word is still the
        // agent acting on the question, so this counts as picking it up too.
        this.markRead();
        const turn = this.ensureLive();
        const tool: ToolCall = {
          id: ev.toolCallId,
          name: ev.toolName,
          // The NAME is a sibling field, so it is deliberately not repeated
          // here -- a panel drawing both would print it twice.
          summary: summarizeArgs(ev.args),
          raw: rawArgs(ev.args),
          state: "running",
          // The answer as it stands RIGHT NOW: everything Ori said before
          // reaching for this tool. Without it a working turn renders as one
          // welded paragraph with a single batch line over the top of it.
          at: turn.text.length,
        };
        turn.tools.push(tool);
        this.openTools.set(ev.toolCallId, { turnId: turn.id, sent: "" });
        this.emit({ t: "tool_add", convId: this.convId, turnId: turn.id, tool: { ...tool } });
        return;
      }

      case "tool_execution_update":
        this.onToolUpdate(ev.toolCallId, ev.partialResult);
        return;

      case "tool_execution_end":
        this.onToolEnd(ev.toolCallId, ev.result, ev.isError === true);
        return;

      // THE idle signal. `agent_end` is NOT: it fires per run and its awaited
      // listeners are still part of settlement, so the agent is not idle there.
      case "agent_settled":
        this.patchState({ busy: false });
        this.settle();
        // The one moment the context can have changed, so the one moment worth
        // asking. Event-driven, once per turn -- never on a timer.
        this.deps.send({ type: "get_session_stats" });
        return;

      // Not in rpc-types.d.ts, but emitted by the real binary on every level
      // that actually moves -- including the one set_model changes on its own,
      // which is the only warning the panel gets that a model switch took the
      // level with it. Silent when the level did not move, so it supplements
      // get_state rather than replacing it.
      case "thinking_level_changed":
        this.patchState({ thinkingLevel: ev.level ?? "" });
        return;

      case "compaction_start":
        this.compactStartedAt = this.deps.now();
        // `total` IS the context size at the moment compaction begins -- the
        // same number the footer shows -- so the receipt's "before" comes from
        // there. Deliberately NOT cleared afterwards: applyCompactEstimate runs
        // twice per compaction (the event, then the response) and its stale
        // threshold is computed from this, so zeroing it between the two would
        // collapse the threshold onto the estimate itself.
        if (this.usg.total > 0) this.compactBeforeTokens = this.usg.total;
        this.patchState({ compacting: true, compactPhase: "summarising" });
        this.emit({ t: "notice", text: this.compactLabel() });
        return;

      case "compaction_end": {
        // The success receipt belongs to the compact RESPONSE, which knows both
        // token counts. This event is read only for what the response cannot
        // report -- abort, and error with its message -- and to stop the clock.
        this.patchState({ compacting: false, compactPhase: "" });
        this.applyCompactEstimate(ev.result?.estimatedTokensAfter);
        // A compaction that finished instantly (a text swap with no summariser
        // call) starts no turn, so no agent_settled follows and the context
        // readout would sit at its pre-compact size. pi rebuilt its messages
        // the moment this fired -- ask now, once.
        if (!ev.aborted && !ev.errorMessage) this.deps.send({ type: "get_session_stats" });
        if (ev.aborted) {
          this.emit({ t: "notice", text: "compaction aborted" });
          return;
        }
        if (ev.errorMessage) {
          this.emit({
            t: "error",
            text: "compact failed: " + firstLine(ev.errorMessage).slice(0, 120),
          });
        }
        return;
      }

      case "summarization_retry_scheduled":
        this.setCompactPhase(
          `provider error, retry ${ev.attempt ?? 1}/${ev.maxAttempts ?? 3} in ` +
            `${Math.round((ev.delayMs ?? 0) / 1000)}s`,
        );
        return;

      case "summarization_retry_attempt_start":
        this.setCompactPhase("retrying the summary");
        return;

      case "summarization_retry_finished":
        this.setCompactPhase("writing the summary");
        return;

      default:
        return;
    }
  }

  /* ---------------------------------------------------------------- *
   * response frames
   * ---------------------------------------------------------------- */

  handleResponse(res: PiResponse): void {
    const failed = res.success === false;

    switch (res.command) {
      // Bookkeeping, all four: read it when it worked and drop it quietly when
      // it did not. A child that cannot list its models is not a reason to
      // break a question, and none of these may paint the transcript red.
      case "get_session_stats":
        if (!failed) this.applyStats(res.data);
        return;
      case "get_commands":
        if (!failed) this.applyCommands(res.data);
        return;
      case "get_available_models":
        if (!failed) this.applyModels(res.data);
        return;
      case "get_available_thinking_levels":
        if (!failed) this.applyLevels(res.data);
        return;
      case "get_state":
        if (!failed) this.applyState(res.data);
        return;

      // A real failure, unlike set_thinking_level below: pi checked the id
      // against its own catalogue and did not find it.
      case "set_model": {
        if (failed) {
          this.emit({ t: "error", text: res.error ?? "set_model failed" });
          return;
        }
        const m = res.data as { provider?: string; id?: string } | undefined;
        if (m?.id) this.patchState({ provider: m.provider ?? "", model: m.id });
        // Both stale the instant the model changed: the level list is per model
        // and set_model re-derives the level itself without telling anyone.
        // Chained off the RESPONSE rather than sent alongside the setter,
        // because responses do not arrive in order -- set_model awaits an auth
        // check, and a get_state queued behind it was observed answering first,
        // with the OLD model in it.
        this.deps.send({ type: "get_available_thinking_levels" });
        this.deps.send({ type: "get_state" });
        return;
      }

      // Deliberately not trusted. It answers success:true for every string it
      // was ever given, clamped ones included. get_state is the only honest
      // answer to "what is it now".
      case "set_thinking_level":
        this.deps.send({ type: "get_state" });
        return;

      case "compact": {
        if (failed) {
          this.patchState({ compacting: false, compactPhase: "" });
          this.emit({ t: "error", text: res.error ?? "compact failed" });
          return;
        }
        const c = (res.data ?? {}) as { tokensBefore?: number; estimatedTokensAfter?: number };
        const secs =
          this.compactStartedAt > 0
            ? Math.round((this.deps.now() - this.compactStartedAt) / 1000)
            : 0;
        this.emit({
          t: "notice",
          text:
            `compacted: ${c.tokensBefore ?? this.compactBeforeTokens ?? "?"} → ` +
            `${c.estimatedTokensAfter ?? "?"} tokens` +
            (secs > 0 ? ` in ${secs}s` : ""),
        });
        this.applyCompactEstimate(c.estimatedTokensAfter);
        this.patchState({ compacting: false, compactPhase: "" });
        this.compactStartedAt = 0;
        return;
      }

      // Success is silent -- the name shows up in the picker on its own.
      case "set_session_name":
        if (failed) this.emit({ t: "error", text: res.error ?? "rename failed" });
        return;

      case "export_html": {
        if (failed) {
          this.emit({ t: "error", text: res.error ?? "export failed" });
          return;
        }
        const p = (res.data as { path?: string } | undefined)?.path ?? "session.html";
        this.emit({ t: "notice", text: "exported: " + p });
        return;
      }

      // The transcript is asked for only after the switch is ACKED -- entries
      // read any earlier belong to the session being switched away from.
      case "switch_session":
        if (failed) this.emit({ t: "error", text: res.error ?? "switch failed" });
        else this.deps.send({ type: "get_entries" });
        return;

      case "get_entries": {
        if (failed) {
          this.emit({ t: "error", text: res.error ?? "get_entries failed" });
          return;
        }
        const d = (res.data ?? {}) as { entries?: unknown[]; leafId?: string | null };
        this.deps.onEntries(d.entries ?? [], d.leafId ?? null);
        // The usage readouts describe a context that has just been replaced
        // wholesale, so re-read them. Driven by the resume, not by a clock.
        this.deps.send({ type: "get_session_stats" });
        return;
      }

      default:
        break;
    }

    // Only a FAILED response reaches here with anything to do: success on
    // `prompt`/`steer` is just an ack that the message was accepted, and the
    // real work arrives as events.
    if (!failed) return;

    const msg = res.error ?? "rejected";
    // Without this the panel WEDGES: `busy` never clears, the composer refuses
    // every later message, and nothing settles the open turn.
    this.patchState({ busy: false });
    this.settle();

    // A pinned thinking level the endpoint refuses would otherwise fail EVERY
    // turn from here on, because it is baked into the child's argv. The
    // upstream names the offender, so take it at its word and unpin it -- one
    // failed turn instead of all of them.
    const bad = /invalid reasoning value:\s*'([^']+)'/.exec(msg);
    if (bad?.[1]) {
      const level = bad[1];
      this.patchState({
        levels: this.st.levels.filter((l) => l !== level),
        ...(this.st.effort === level ? { effort: "" } : {}),
      });
      this.emit({
        t: "error",
        text: `'${level}' is not a thinking level this endpoint accepts`,
      });
      return;
    }
    this.emit({ t: "error", text: msg });
  }

  /* ---------------------------------------------------------------- *
   * the streaming sink
   * ---------------------------------------------------------------- */

  private live(): Turn | null {
    if (this.liveId === null) return null;
    const t = this.byId.get(this.liveId);
    return t && t.role === "assistant" && t.pending ? t : null;
  }

  /**
   * A TURN THE PANEL DID NOT OPEN.
   *
   * Every turn used to start from `ask()`, so a row was always waiting. That
   * stopped being true the moment the agent could be woken by something other
   * than the user: the bash tool backgrounds a long command and wakes the agent
   * when it finishes, and the first delta of THAT turn arrived with no pending
   * row -- so it was appended to the end of the last sentence of the answer that
   * had already settled ("...as PID 305128.BACKGROUNDED - done, exit 0.").
   */
  private ensureLive(): Turn {
    const live = this.live();
    if (live) return live;
    const t = this.addTurn("assistant", { pending: true });
    this.liveId = t.id;
    this.roundBase = 0;
    // The agent is demonstrably working -- it is mid-sentence. Nothing else is
    // going to set this, because nothing here asked it a question.
    if (!this.st.busy) this.patchState({ busy: true });
    this.startClock();
    return t;
  }

  private grow(field: "text" | "thinking", delta: string): void {
    if (delta === "") return;
    // The first thing back after a question is the receipt for that question.
    this.markRead();
    const turn = this.ensureLive();
    turn[field] += delta;
    this.emit({ t: "turn_delta", convId: this.convId, turnId: turn.id, field, delta });

    const now = this.deps.now();
    if (this.lastAppendAt > 0) {
      const gap = now - this.lastAppendAt;
      if (gap > 0 && gap < GEN_GAP_CAP_MS) this.genMs += gap;
    }
    this.lastAppendAt = now;
  }

  private startClock(): void {
    const now = this.deps.now();
    this.turnStartedAt = now;
    this.outputBase = this.usg.output;
    this.genMs = 0;
    // A turn opens at full flow, so the first seconds -- before a single token
    // has landed -- read as movement rather than as a stall left over from the
    // previous answer.
    this.lastAppendAt = now;
  }

  /* ---------------------------------------------------------------- *
   * tools
   * ---------------------------------------------------------------- */

  private onToolUpdate(toolCallId: string, partial: PiToolResult | undefined): void {
    const open = this.openTools.get(toolCallId);
    if (!open) return;
    const turn = this.byId.get(open.turnId);
    const tool = turn?.tools.find((x) => x.id === toolCallId);
    if (!turn || !tool) return;

    // pi's `partialResult` is CUMULATIVE, not a delta. Emitting it unfiltered
    // renders the prefix N times. The diff is what decides whether anything is
    // emitted at all; what goes on the wire is the authoritative full text,
    // because `tool_patch` replaces rather than appends.
    const full = tail(flattenContent(partial?.content), TOOL_RESULT_CAP);
    if (full === open.sent) return;
    open.sent = full;
    tool.result = full;
    this.emit({
      t: "tool_patch",
      convId: this.convId,
      turnId: turn.id,
      toolId: toolCallId,
      patch: { result: full },
    });
  }

  private onToolEnd(toolCallId: string, result: PiToolResult | undefined, isError: boolean): void {
    const open = this.openTools.get(toolCallId);
    this.openTools.delete(toolCallId);
    const turn = open ? this.byId.get(open.turnId) : undefined;
    const tool = turn?.tools.find((x) => x.id === toolCallId);

    if (turn && tool) {
      const text = tail(flattenContent(result?.content), TOOL_RESULT_CAP);
      const patch: Partial<ToolCall> = { state: isError ? "error" : "ok" };
      if (text !== "" || tool.result !== undefined) patch.result = text;
      Object.assign(tool, patch);
      this.emit({ t: "tool_patch", convId: this.convId, turnId: turn.id, toolId: toolCallId, patch });
    }

    // A tool that RETURNED is not necessarily a job that FINISHED. The bash
    // tool auto-backgrounds anything still alive at its timeout: it resolves
    // immediately with a pid and a log file, so from the protocol's point of
    // view the call is over while the command is still running. `result` is the
    // tool's own return value verbatim -- toJsonEvent() passes every event but
    // message_update straight through -- so `details.backgrounded` is exactly
    // what the extension set.
    const det = result?.details;
    if (field(det, "backgrounded") !== true) return;
    const pid = num(field(det, "pid"));
    if (!pid) return;
    this.addBgJob(
      pid,
      // The tool says what kind of thing it handed back when it knows -- a
      // subagent reports "agent". Only bash has to be inferred, and there the
      // tell is whether it was given an alarm to watch for.
      bgKind(field(det, "kind"), field(det, "watching") === true),
      // The intent first, the command only if there was none: a tray row
      // answers "what is running and why", and an elided shell one-liner
      // answers neither.
      str(field(det, "label")) || str(field(det, "command")),
      str(field(det, "name")),
    );
  }

  private addBgJob(pid: number, kind: BgKind, label: string, name: string): void {
    this.bgJobs.set(pid, { pid, kind, label, name, since: this.deps.now() });
    this.emit({ t: "bg", convId: this.convId, jobs: this.bg });
  }

  private dropBgJob(pid: number): void {
    if (!this.bgJobs.delete(pid)) return;
    this.emit({ t: "bg", convId: this.convId, jobs: this.bg });
  }

  /* ---------------------------------------------------------------- *
   * message_end -- background jobs, THE SEAM, and errors
   * ---------------------------------------------------------------- */

  private onMessageEnd(m: PiMessage | undefined): void {
    if (!m) return;

    // The other end of a background job. The bash tool announces a finished one
    // as a CUSTOM message, which pi appends to the session and emits here like
    // any other -- so this clears the badge, and nothing has to poll a process
    // table to notice.
    if (m.customType === "bg_process_done") {
      const pid = num(field(m.details, "pid"));
      if (pid) this.dropBgJob(pid);
      return;
    }

    // THE SEAM. pi echoing a user message back is it saying "I have taken this
    // off the queue and put it in the conversation", which is exactly the moment
    // the answer below stops being the old one. See splitAtSeam.
    if (m.role === "user" && this.steerQueue.length > 0) {
      if (this.takeSteer(flattenContent(m.content))) return;
    }

    if (m.role === "assistant") this.reconcile(m);

    // The failure a dead provider actually produces, which is none of the shapes
    // this file already watches for: no `response success:false` and no error
    // event -- the turn starts, runs, settles normally, and the answer is simply
    // EMPTY, with the reason buried in the assistant message. Only the first
    // clause is kept: pi's message carries the URL, the response body and a JS
    // stack, which is a paragraph on a strip sized for a line.
    if (m.stopReason === "error") {
      this.emit({
        t: "error",
        text: firstLine(m.errorMessage ?? "the model returned an error"),
      });
    }
  }

  /**
   * `message_update` deliberately strips the cumulative snapshot (see
   * json-event.d.ts), so the deltas are the only running copy of the text and a
   * dropped one would never heal. `message_end.message` IS authoritative -- but
   * only for its own LLM ROUND: a tool-using turn emits several of these, each
   * carrying just that round's message. So the comparison is against everything
   * written since the matching `message_start`.
   */
  private reconcile(m: PiMessage): void {
    const turn = this.live();
    if (!turn) return;
    const base = Math.min(this.roundBase, turn.text.length);
    const truth = flattenContent(m.content);
    if (turn.text.slice(base) === truth) return;
    turn.text = turn.text.slice(0, base) + truth;
    this.emit({ t: "turn_patch", convId: this.convId, turnId: turn.id, patch: { text: turn.text } });
  }

  /**
   * Match an echo against the outstanding steers, consume it, and split.
   * Removed BY POSITION rather than popped from the head: pi delivers in the
   * order it received them, so the head is what normally matches, but a queue
   * that ASSUMED it would desyncs permanently the first time that fails to hold.
   * Duplicates are legal, which is exactly why value-equality alone cannot be
   * the removal rule.
   *
   * Matched EXACTLY, not trimmed. What was sent is already trimmed and pi echoes
   * what it received, so trimming this end could only hide a genuine mismatch --
   * and a mismatch has to fall through rather than split at the wrong place.
   */
  private takeSteer(text: string): boolean {
    const at = this.steerQueue.findIndex((q) => q.text === text);
    if (at < 0) return false;
    const entry = this.steerQueue[at]!;
    this.steerQueue = [...this.steerQueue.slice(0, at), ...this.steerQueue.slice(at + 1)];
    this.splitAtSeam(entry.turnId);
    return true;
  }

  /**
   * The seam. Everything before it belongs to the answer that was interrupted;
   * everything after it is the reply to the steer.
   *
   * Keyed on the ECHO and not on the `turn_start` just before it. `turn_start`
   * is per LLM round, not per request -- an ordinary tool-using request emits
   * two and one with a background job emits three -- and the first after a steer
   * is the seam only because pi drains its queue at every turn boundary, which
   * is a scheduler detail. `stopReason` is not a discriminator either: the seam
   * after a mid-tool-call steer sits at a turn whose preceding `message_end` had
   * stopReason "toolUse". The echo is the statement.
   */
  private splitAtSeam(questionId: string): void {
    const live = this.live();
    if (live) {
      if (!hasContent(live)) {
        // The argument for keeping a text-empty row -- it is still the receipt
        // for the work you interrupted -- rests entirely on that work existing.
        // A row with no text, no reasoning and no calls draws as a blank band.
        this.dropTurn(live.id);
      } else {
        // Close it where pi ended it, and PAY it: `busy` spans both turns, so
        // billing only on the busy edge would leave the answer you interrupted
        // with no receipt at all.
        this.closeTurn(live);
      }
    }
    this.liveId = null;
    // The clock and the token baseline restart with the answer they describe,
    // so the second receipt measures the redirect and not the whole request.
    this.startClock();

    // UNDER ITS OWN QUESTION, which with two steers outstanding is not the end
    // of the list: pi answers them one at a time, so at the first seam the rows
    // already read [answer][steer 1][steer 2] and appending would file steer 1's
    // reply under steer 2. Located by ID, resolved NOW -- the position is read
    // after the branch above may have dropped a row, and two steers carrying the
    // same text still resolve to different rows.
    const q = this.turnList.findIndex((t) => t.id === questionId);
    const into = q < 0 ? this.turnList.length : q + 1;

    const a = this.addTurn("assistant", { pending: true }, into);
    this.liveId = a.id;
    this.roundBase = 0;
  }

  /* ---------------------------------------------------------------- *
   * settling and cost
   * ---------------------------------------------------------------- */

  private settle(): void {
    // A steer that never reached its boundary -- the turn ended first, was
    // aborted, or the child died under it -- must not split the NEXT question's
    // turn. But it must not vanish in silence either: that row is a message the
    // user sent that got no answer and no explanation. "never answered" rather
    // than "never delivered", which is the stronger claim and not one this can
    // make: steer inside the first second of a turn and the ORIGINAL question's
    // echo arrives with the steer already queued, matching nothing.
    if (this.steerQueue.length > 0) {
      const lost = this.steerQueue.length;
      this.steerQueue = [];
      this.emit({
        t: "notice",
        text: `${lost === 1 ? "that steer" : lost + " steers"} never got an answer -- the turn ended first`,
      });
    }

    // The live turn, or the newest assistant turn as a fallback: a transcript
    // restored from disk has rows but no streaming target, and settling it is
    // still the right thing.
    const t = this.live() ?? this.lastAssistant();
    this.liveId = null;
    if (!t || !t.pending) return;
    this.closeTurn(t);
  }

  private lastAssistant(): Turn | null {
    for (let i = this.turnList.length - 1; i >= 0; i--) {
      const t = this.turnList[i];
      if (t && t.role === "assistant") return t;
    }
    return null;
  }

  private closeTurn(t: Turn): void {
    const patch: Partial<Turn> = { pending: false, settledAt: this.deps.now() };
    const cost = this.costFor(t);
    if (cost) patch.cost = cost;
    Object.assign(t, patch);
    this.emit({ t: "turn_patch", convId: this.convId, turnId: t.id, patch });
  }

  /**
   * The receipt for one ANSWER, which is not the same as one request: `busy`
   * spans a steer, and `agent_settled` fires once across both turns.
   *
   * A turn with nothing on it gets no receipt -- a bare "0.4s" floating between
   * two turns is an artefact, and the seam makes it reachable twice as often.
   */
  private costFor(t: Turn): TurnCost | undefined {
    if (!hasContent(t) || this.turnStartedAt <= 0) return undefined;
    const output = this.turnOutput();
    return {
      input: this.usg.input,
      output,
      seconds: (this.deps.now() - this.turnStartedAt) / 1000,
      tokensPerSecond: this.genMs > GEN_MIN_MS && output > 0 ? output / (this.genMs / 1000) : 0,
    };
  }

  /**
   * Output tokens produced by THIS turn. `usage.output` has been seen reset per
   * turn; were it ever cumulative across the session instead, the baseline turns
   * it into the same number either way -- a cumulative counter only ever grows
   * past the baseline, a per-turn one starts under it.
   */
  private turnOutput(): number {
    return this.usg.output >= this.outputBase ? this.usg.output - this.outputBase : this.usg.output;
  }

  /* ---------------------------------------------------------------- *
   * delivery receipts
   * ---------------------------------------------------------------- */

  /**
   * Nothing in the protocol acknowledges a message by id, so Read is INFERRED:
   * the first token or tool call after a question went out is the agent
   * demonstrably working on it. Weaker than a real read receipt, and stronger
   * than the alternative -- which was to show nothing and let a 7-second cold
   * spawn look like a message that had vanished.
   */
  private markRead(): void {
    if (!this.awaitingRead) return;
    this.awaitingRead = false;
    for (let i = this.turnList.length - 1; i >= 0; i--) {
      const t = this.turnList[i];
      if (!t || t.role !== "user") continue;
      if (t.delivery < Delivery.Read) {
        t.delivery = Delivery.Read;
        this.emit({
          t: "turn_patch",
          convId: this.convId,
          turnId: t.id,
          patch: { delivery: Delivery.Read },
        });
      }
      return;
    }
  }

  /* ---------------------------------------------------------------- *
   * usage
   * ---------------------------------------------------------------- */

  private applyUsage(u: PiUsage): void {
    const input = num(u.input);
    const output = num(u.output);
    const total = num(u.totalTokens) || input + output;
    if (total <= 0) return;
    this.usg = { ...this.usg, input, output, total };
    this.emit({ t: "usage", convId: this.convId, usage: this.usage });
  }

  /**
   * pi reports NO usage between a compaction and the first answer after it, so
   * without this the readout sits at the pre-compact size -- showing a context
   * that was just thrown away. The estimate is marked, and only a real reading
   * BELOW the pre-compact total may replace it.
   */
  private applyCompactEstimate(after: number | undefined): void {
    const a = num(after);
    if (a <= 0) return;
    // Idempotent: compaction_end and the compact response both carry the same
    // estimate, and the second must not re-derive the threshold off the first's
    // own result.
    if (this.usg.estimated && this.usg.total === a) return;
    this.staleAbove = Math.max(this.compactBeforeTokens, this.usg.total);
    this.usg = { ...this.usg, total: a, estimated: true };
    this.emit({ t: "usage", convId: this.convId, usage: this.usage });
  }

  private applyStats(data: unknown): void {
    const s = (data ?? {}) as {
      sessionFile?: string;
      sessionId?: string;
      contextUsage?: { tokens?: number | null; contextWindow?: number };
    };
    // The same response carries which file this conversation is, which is the
    // only place that fact is available without an extra round trip.
    if (s.sessionFile) {
      this.patchState({ sessionFile: s.sessionFile, sessionId: s.sessionId ?? this.st.sessionId });
    }
    const cu = s.contextUsage;
    if (!cu) return;

    const next = { ...this.usg };
    let changed = false;
    const window = num(cu.contextWindow);
    if (window > 0 && window !== next.contextWindow) {
      next.contextWindow = window;
      changed = true;
    }
    const t = num(cu.tokens);
    // A reading at or above the pre-compact size, while an estimate stands, is
    // the number compaction just invalidated. Keep the estimate.
    const stale = next.estimated && this.staleAbove > 0 && t >= this.staleAbove;
    if (t > 0 && !stale) {
      changed = changed || next.total !== t || next.estimated;
      next.total = t;
      next.estimated = false;
      this.staleAbove = 0;
    }
    if (!changed) return;
    this.usg = next;
    this.emit({ t: "usage", convId: this.convId, usage: this.usage });
  }

  /* ---------------------------------------------------------------- *
   * catalogue readings
   * ---------------------------------------------------------------- */

  private applyState(data: unknown): void {
    const s = (data ?? {}) as {
      model?: { provider?: string; id?: string };
      thinkingLevel?: string;
      sessionId?: string;
      sessionFile?: string;
      sessionName?: string;
    };
    const patch: Partial<SessionState> = { thinkingLevel: s.thinkingLevel ?? "" };
    if (s.model?.id) {
      patch.provider = s.model.provider ?? "";
      patch.model = s.model.id;
    }
    if (s.sessionId) patch.sessionId = s.sessionId;
    if (s.sessionFile) patch.sessionFile = s.sessionFile;
    if (s.sessionName !== undefined) patch.sessionName = s.sessionName;
    this.patchState(patch);
  }

  /** Trimmed to the three fields anything downstream reads: the live answer is
   *  45KB of baseUrls, per-token costs and window sizes. */
  private applyModels(data: unknown): void {
    const list = ((data ?? {}) as { models?: Array<Record<string, unknown>> }).models ?? [];
    if (list.length === 0) return;
    const models: ModelChoice[] = list.map((m) => ({
      provider: str(m["provider"]),
      id: str(m["id"]),
      name: str(m["name"]) || str(m["id"]),
    }));
    this.emit({ t: "models", models });
  }

  private applyLevels(data: unknown): void {
    const list = ((data ?? {}) as { levels?: unknown[] }).levels ?? [];
    if (list.length === 0) return;
    this.patchState({ levels: list.map(str) });
  }

  /**
   * Replaced unconditionally. The child spawns with no --skill, so get_commands
   * answers with SKILLS ONLY -- an empty list is a true statement ("no skills
   * installed"), and swallowing it left the last deleted skill in the menu
   * forever.
   */
  private applyCommands(data: unknown): void {
    const list = ((data ?? {}) as { commands?: Array<Record<string, unknown>> }).commands ?? [];
    const commands: SlashCommand[] = list.map((c) => ({
      name: str(c["name"]),
      description: str(c["description"]),
      source: commandSource(c["source"]),
    }));
    this.emit({ t: "commands", commands });
  }

  /* ---------------------------------------------------------------- *
   * compaction phase
   * ---------------------------------------------------------------- */

  private setCompactPhase(phase: string): void {
    if (!this.st.compacting) return;
    this.patchState({ compactPhase: phase });
    this.emit({ t: "notice", text: this.compactLabel() });
  }

  /** pi streams nothing from the summariser call itself, so the honest display
   *  is the phase the EVENTS name and never a guess about how far along it is. */
  private compactLabel(): string {
    const t = this.compactBeforeTokens;
    const size = t <= 0 ? "?" : t < 10000 ? String(t) : Math.round(t / 1000) + "k";
    return `compacting · ${size} tokens · ${this.st.compactPhase}`;
  }

  /* ---------------------------------------------------------------- *
   * turn list -- the ONLY place turns are created, removed or reordered
   * ---------------------------------------------------------------- */

  private addTurn(role: Turn["role"], init: Partial<Turn>, index?: number): Turn {
    const t: Turn = {
      id: this.deps.newId(),
      role,
      text: "",
      thinking: "",
      tools: [],
      images: [],
      pending: false,
      delivery: Delivery.Sent,
      ...init,
    };
    this.byId.set(t.id, t);
    if (index === undefined || index >= this.turnList.length) {
      this.turnList.push(t);
      this.emit({ t: "turn_add", convId: this.convId, turn: cloneTurn(t) });
    } else {
      this.turnList.splice(index, 0, t);
      // Ids, not indices: an insert here re-keys NOTHING, which is the whole
      // reason shiftRowKeys() does not exist in this file.
      this.emit({ t: "turn_add", convId: this.convId, turn: cloneTurn(t), index });
    }
    return t;
  }

  private dropTurn(id: string): void {
    const i = this.turnList.findIndex((t) => t.id === id);
    if (i < 0) return;
    this.turnList.splice(i, 1);
    this.byId.delete(id);
    if (this.liveId === id) this.liveId = null;
    for (const [k, v] of this.openTools) if (v.turnId === id) this.openTools.delete(k);
    this.emit({ t: "turn_drop", convId: this.convId, turnId: id });
  }
}

/* ------------------------------------------------------------------ *
 * small pure helpers
 * ------------------------------------------------------------------ */

/**
 * Whether a turn is worth drawing: the answer, the work, or the reasoning. ONE
 * predicate, so the two places that ask -- the cost receipt and the seam's drop
 * -- cannot answer differently.
 *
 * `thinking` is in it because leaving it out is a mistake that was made twice:
 * a capture measured 117 SECONDS of thinking_delta before the first text_delta,
 * and a steer landing in that window closes a turn carrying nothing but
 * reasoning, which the panel does draw.
 */
export function hasContent(t: Turn): boolean {
  return t.text !== "" || t.thinking !== "" || t.tools.length > 0;
}

function cloneTurn(t: Turn): Turn {
  return { ...t, tools: t.tools.map((x) => ({ ...x })), images: t.images.map((x) => ({ ...x })) };
}

/**
 * A turn on its way into a SNAPSHOT, which is the one place the reasoning is
 * dead weight.
 *
 * The panel draws `thinking` only while a turn is being written -- TurnDelegate
 * gates the reasoning block on `pending && thought !== ""`, and a settled turn
 * shows its cost receipt in that slot instead. So every settled turn's
 * reasoning is parsed, copied into a ListModel role and never turned into a
 * single pixel. Measured on a real 235-turn transcript: 487,012 of 1,200,569
 * snapshot bytes, 41%.
 *
 * The live turn keeps it, because that one IS drawn -- and it is the only turn
 * that can be pending, so this is one field on one row.
 *
 * NOT dropped from the type, and not dropped anywhere else: `turn_add`,
 * `turn_patch` and `turn_delta` all still carry reasoning, because the panel
 * needs it as the turn arrives. A panel from before this change reads exactly
 * the same shape and simply has an empty string where it never looked.
 */
function cloneForSnapshot(t: Turn): Turn {
  const c = cloneTurn(t);
  if (!c.pending) c.thinking = "";
  return c;
}

function firstLine(s: string): string {
  return (s.split(";")[0] ?? "").split("\n")[0] ?? "";
}

/** One field off a `details` bag pi declares as `unknown`. */
function field(bag: unknown, key: string): unknown {
  return bag && typeof bag === "object" ? (bag as Record<string, unknown>)[key] : undefined;
}

function num(v: unknown): number {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function str(v: unknown): string {
  return v === undefined || v === null ? "" : String(v);
}

function bgKind(kind: unknown, watching: boolean): BgKind {
  const k = str(kind);
  if (k === "job" || k === "monitor" || k === "agent" || k === "speak") return k;
  return watching ? "monitor" : "job";
}

function commandSource(v: unknown): SlashCommand["source"] {
  const s = str(v);
  return s === "extension" || s === "prompt" || s === "skill" || s === "panel" ? s : "extension";
}
