/**
 * conversation.test.ts -- the HostEvent stream a recorded-shape pi session
 * produces. No socket, no child, no filesystem: the clock and the id generator
 * are injected, so every assertion here is exact rather than approximate.
 *
 * The event sequences below follow real captures documented in PiSession.qml
 * (the frame ingest at 2722-3179 and the steer capture at 1030-1050): usage
 * rides on message_update, message_end carries the authoritative message,
 * agent_settled is the idle signal and agent_end is not.
 */

import { describe, expect, test } from "bun:test";
import { Conversation, type PiEvent, type PiResponse } from "../src/conversation";
import type { JsonAgentSessionEvent, RpcResponse } from "../src/pi/pi-types";
import { Delivery, type HostEvent } from "../src/protocol";

/**
 * COMPILE-TIME PROOF that the shapes conversation.ts reads are widenings of
 * pi's OWN declarations rather than a parallel invention. `tsc --noEmit` fails
 * here if pi's event or response union ever grows an arm the module cannot
 * accept, which is the guarantee ARCHITECTURE.md rule 3 is after -- and it is
 * the check that lets `handleEvent` take a frame straight off pi's stdout.
 */
// Tupled deliberately: a bare `A extends B` DISTRIBUTES over a union, and the
// arms that fail contribute `never` to a union that is still `true` -- a check
// that can never fail. `[A] extends [B]` tests the whole union at once.
type Assignable<A, B> = [A] extends [B] ? true : never;
const _piEventsFit: Assignable<JsonAgentSessionEvent, PiEvent> = true;
const _piResponsesFit: Assignable<RpcResponse, PiResponse> = true;
void _piEventsFit;
void _piResponsesFit;

/** Deterministic harness: ids are t1, t2, ... and the clock only moves when a
 *  test moves it. */
function harness(start = 1_000_000) {
  const events: HostEvent[] = [];
  const sent: Array<{ type: string }> = [];
  let clock = start;
  let n = 0;
  const conv = new Conversation("c1", (e) => events.push(e), {
    now: () => clock,
    newId: () => `t${++n}`,
    send: (c) => sent.push(c as { type: string }),
  });
  return {
    conv,
    events,
    sent,
    tick: (ms: number) => {
      clock += ms;
    },
    at: () => clock,
    /** Every emitted event of one kind, in order. */
    of: <T extends HostEvent["t"]>(t: T) =>
      events.filter((e) => e.t === t) as Array<Extract<HostEvent, { t: T }>>,
    drain: () => events.splice(0, events.length),
  };
}

const usage = (input: number, output: number) => ({
  input,
  output,
  totalTokens: input + output,
});

const textDelta = (delta: string): PiEvent => ({
  type: "message_update",
  assistantMessageEvent: { type: "text_delta", delta },
});

const thinkDelta = (delta: string): PiEvent => ({
  type: "message_update",
  assistantMessageEvent: { type: "thinking_delta", delta },
});

const assistantEnd = (text: string, stopReason = "stop"): PiEvent => ({
  type: "message_end",
  message: { role: "assistant", content: [{ type: "text", text }], stopReason },
});

describe("a plain turn", () => {
  test("emits question, sink, deltas, receipt -- in that order", () => {
    const h = harness();
    const { turnId, steer } = h.conv.ask("hello");
    expect(steer).toBe(false);
    h.conv.markSent(turnId);

    h.conv.handleEvent({ type: "message_start", message: { role: "assistant" } });
    h.conv.handleEvent({ type: "message_update", usage: usage(100, 0) });
    h.tick(300);
    h.conv.handleEvent(textDelta("hi "));
    h.tick(300);
    h.conv.handleEvent(textDelta("there"));
    h.conv.handleEvent({ type: "message_update", usage: usage(100, 12) });
    h.conv.handleEvent(assistantEnd("hi there"));
    h.tick(400);
    h.conv.handleEvent({ type: "agent_settled" });

    expect(h.events.map((e) => e.t)).toEqual([
      "turn_add", // the question
      "state", // busy = true
      "turn_add", // the sink, opened before a single token arrives
      "turn_patch", // delivery: Sent
      "usage",
      "turn_patch", // delivery: Read -- inferred from the first token
      "turn_delta",
      "turn_delta",
      "usage",
      "state", // busy = false
      "turn_patch", // settled + cost
    ]);

    expect(h.conv.turns.map((t) => [t.role, t.text])).toEqual([
      ["user", "hello"],
      ["assistant", "hi there"],
    ]);

    const user = h.conv.turns[0]!;
    expect(user.delivery).toBe(Delivery.Read);

    const answer = h.conv.turns[1]!;
    expect(answer.pending).toBe(false);
    expect(answer.settledAt).toBe(h.at());
    // 1.0s of wall clock, but only the two 300ms delta gaps count as
    // generation -- the 400ms tail is the turn ending, not the model writing.
    expect(answer.cost).toEqual({
      input: 100,
      output: 12,
      seconds: 1.0,
      tokensPerSecond: 12 / 0.6,
    });

    // agent_settled is the one moment the context can have changed.
    expect(h.sent).toEqual([{ type: "get_session_stats" }]);
  });

  test("deltas are appends, never the cumulative string", () => {
    const h = harness();
    h.conv.ask("q");
    h.drain();
    h.conv.handleEvent(textDelta("ab"));
    h.conv.handleEvent(textDelta("cd"));
    expect(h.of("turn_delta").map((e) => e.delta)).toEqual(["ab", "cd"]);
    expect(h.conv.turns[1]!.text).toBe("abcd");
  });

  test("thinking and text are separate streams", () => {
    const h = harness();
    h.conv.ask("q");
    h.drain();
    h.conv.handleEvent(thinkDelta("weighing it up"));
    h.conv.handleEvent(textDelta("done"));
    expect(h.of("turn_delta").map((e) => [e.field, e.delta])).toEqual([
      ["thinking", "weighing it up"],
      ["text", "done"],
    ]);
    expect(h.conv.turns[1]!.thinking).toBe("weighing it up");
    expect(h.conv.turns[1]!.text).toBe("done");
  });

  test("message_end is authoritative -- a dropped delta is reconciled", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent({ type: "message_start", message: { role: "assistant" } });
    h.conv.handleEvent(textDelta("hi th"));
    h.drain();
    // The wire lost "ere". message_update strips the cumulative snapshot, so
    // nothing but message_end can heal this.
    h.conv.handleEvent(assistantEnd("hi there"));
    expect(h.of("turn_patch").map((e) => e.patch)).toEqual([{ text: "hi there" }]);
    expect(h.conv.turns[1]!.text).toBe("hi there");
  });

  test("a wake with no open turn opens its own turn rather than welding", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("first answer"));
    h.conv.handleEvent({ type: "agent_settled" });
    h.drain();

    // The bash tool wakes the agent when a backgrounded command finishes. The
    // first delta of THAT turn used to land on the settled answer's last
    // sentence: "...as PID 305128.BACKGROUNDED - done, exit 0."
    h.conv.handleEvent(textDelta("BACKGROUNDED - done"));
    expect(h.conv.turns.map((t) => t.text)).toEqual(["q", "first answer", "BACKGROUNDED - done"]);
    expect(h.of("state")[0]!.patch).toEqual({ busy: true });
  });
});

describe("a turn with two tool calls interleaved with text", () => {
  test("each call records where in the prose it happened", () => {
    const h = harness();
    h.conv.ask("build it");
    h.drain();

    h.conv.handleEvent(textDelta("Let me look. "));
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "read",
      args: { file_path: "/tmp/foo.ts", description: "read the entry point" },
    });
    h.conv.handleEvent({
      type: "tool_execution_end",
      toolCallId: "tc1",
      result: { content: [{ type: "text", text: "export const a = 1" }] },
      isError: false,
    });
    h.conv.handleEvent(textDelta("Now the build."));
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc2",
      toolName: "bash",
      args: { command: "bun run build", description: "build the project" },
    });
    h.conv.handleEvent({
      type: "tool_execution_end",
      toolCallId: "tc2",
      result: { content: [{ type: "text", text: "boom" }] },
      isError: true,
    });

    const answer = h.conv.turns[1]!;
    expect(answer.tools.map((x) => [x.name, x.summary, x.raw, x.state, x.at])).toEqual([
      ["read", "read the entry point", "/tmp/foo.ts", "ok", "Let me look. ".length],
      ["bash", "build the project", "bun run build", "error", "Let me look. Now the build.".length],
    ]);

    expect(h.of("tool_add").map((e) => e.tool.id)).toEqual(["tc1", "tc2"]);
    expect(h.of("tool_patch").map((e) => [e.toolId, e.patch.state, e.patch.result])).toEqual([
      ["tc1", "ok", "export const a = 1"],
      ["tc2", "error", "boom"],
    ]);
  });

  test("a tool call before any text still marks the question Read", () => {
    const h = harness();
    const { turnId } = h.conv.ask("do it");
    h.conv.markSent(turnId);
    h.drain();
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "bash",
      args: { command: "ls" },
    });
    expect(h.conv.turns[0]!.delivery).toBe(Delivery.Read);
  });

  test("cumulative partialResult emits only the NEW characters", () => {
    const h = harness();
    h.conv.ask("run it");
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "bash",
      args: { command: "make" },
    });
    h.drain();

    // pi's partialResult is CUMULATIVE, not a delta. Unfiltered, the panel
    // renders the prefix N times.
    const partial = (text: string): PiEvent => ({
      type: "tool_execution_update",
      toolCallId: "tc1",
      partialResult: { content: [{ type: "text", text }] },
    });
    h.conv.handleEvent(partial("line one\n"));
    h.conv.handleEvent(partial("line one\nline two\n"));
    h.conv.handleEvent(partial("line one\nline two\n")); // no growth at all
    h.conv.handleEvent(partial("line one\nline two\nline three\n"));

    const patches = h.of("tool_patch");
    // Three emissions, not four: the repeat carried nothing new.
    expect(patches.length).toBe(3);
    // Each patch is the authoritative text with the prefix present EXACTLY once
    // -- never "line one\nline one\nline two\n".
    expect(patches.map((p) => p.patch.result)).toEqual([
      "line one\n",
      "line one\nline two\n",
      "line one\nline two\nline three\n",
    ]);
    for (const p of patches) {
      const r = p.patch.result!;
      expect(r.split("line one").length - 1).toBe(1);
    }
    // The new characters each emission contributed, which is what the diff sees.
    const grown = patches.map((p, i) =>
      p.patch.result!.slice(i === 0 ? 0 : patches[i - 1]!.patch.result!.length),
    );
    expect(grown).toEqual(["line one\n", "line two\n", "line three\n"]);
  });

  test("a backgrounded tool surfaces a BgJob and bg_process_done drops it", () => {
    const h = harness();
    h.conv.ask("watch the log");
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "bash",
      args: { command: "tail -f build.log" },
    });
    h.drain();

    h.conv.handleEvent({
      type: "tool_execution_end",
      toolCallId: "tc1",
      result: {
        content: [{ type: "text", text: "backgrounded as 4242" }],
        // `watching` is the only tell that separates a monitor from a job.
        details: { backgrounded: true, pid: 4242, watching: true, label: "tail the build log" },
      },
      isError: false,
    });
    // convId and origin are stamped at start: a backgrounded command outlives
    // the switch away from the conversation that started it, so the tray needs
    // to know whose it is. `origin` is the opening question here because the
    // conversation has not been given a name.
    expect(h.conv.bg).toEqual([
      {
        pid: 4242,
        kind: "monitor",
        label: "tail the build log",
        name: "",
        since: h.at(),
        convId: h.conv.convId,
        origin: expect.any(String),
      },
    ]);

    h.conv.handleEvent({
      type: "message_end",
      message: { role: "custom", customType: "bg_process_done", details: { pid: 4242 } },
    });
    expect(h.conv.bg).toEqual([]);
    expect(h.of("bg").map((e) => e.jobs.length)).toEqual([1, 0]);
  });
});

describe("a turn that errors", () => {
  test("stopReason error surfaces the first clause only", () => {
    const h = harness();
    h.conv.ask("q");
    h.drain();
    // The failure a dead provider actually produces: no `response
    // success:false` and no error event -- the turn settles normally and the
    // answer is simply empty.
    h.conv.handleEvent({
      type: "message_end",
      message: {
        role: "assistant",
        content: [],
        stopReason: "error",
        errorMessage:
          "OAuth refresh failed for anthropic: Refresh token expired; POST https://x/y\n  at f (a.ts:1)",
      },
    });
    h.conv.handleEvent({ type: "agent_settled" });

    expect(h.of("error").map((e) => e.text)).toEqual([
      "OAuth refresh failed for anthropic: Refresh token expired",
    ]);
    // An empty answer earns no receipt -- a bare "0.4s" floating between two
    // turns is an artefact.
    expect(h.conv.turns[1]!.cost).toBeUndefined();
    expect(h.conv.turns[1]!.pending).toBe(false);
  });

  test("a response success:false clears busy and settles", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("partial"));
    h.drain();

    const res: PiResponse = {
      type: "response",
      command: "prompt",
      success: false,
      error: "already processing",
    };
    h.conv.handleResponse(res);

    expect(h.conv.state.busy).toBe(false);
    expect(h.conv.turns[1]!.pending).toBe(false);
    expect(h.of("error").map((e) => e.text)).toEqual(["already processing"]);
  });

  test("a refused thinking level is unpinned instead of poisoning every turn", () => {
    const h = harness();
    h.conv.handleResponse({
      type: "response",
      command: "get_available_thinking_levels",
      success: true,
      data: { levels: ["off", "minimal", "low", "high"] },
    });
    h.conv.patchState({ effort: "minimal" });
    h.drain();

    h.conv.handleResponse({
      type: "response",
      command: "prompt",
      success: false,
      error: "400 invalid reasoning value: 'minimal' (must be \"high\", \"low\")",
    });

    expect(h.conv.state.levels).toEqual(["off", "low", "high"]);
    expect(h.conv.state.effort).toBe("");
    expect(h.of("error").map((e) => e.text)).toEqual([
      "'minimal' is not a thinking level this endpoint accepts",
    ]);
  });

  test("a failed bookkeeping probe is dropped quietly", () => {
    const h = harness();
    h.conv.ask("q");
    h.drain();
    for (const command of [
      "get_session_stats",
      "get_commands",
      "get_available_models",
      "get_available_thinking_levels",
      "get_state",
    ]) {
      h.conv.handleResponse({ type: "response", command, success: false, error: "nope" });
    }
    // A child that cannot list its models is not a reason to break a question.
    expect(h.events).toEqual([]);
    expect(h.conv.state.busy).toBe(true);
  });
});

describe("a compaction", () => {
  test("start, retry, end and the response drive compactPhase and the notice", () => {
    const h = harness();
    // A measured context to compact away.
    h.conv.handleResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { contextUsage: { tokens: 120_000, contextWindow: 131_072 } },
    });
    h.drain();

    h.conv.handleEvent({ type: "compaction_start" });
    expect(h.conv.state.compacting).toBe(true);
    expect(h.conv.state.compactPhase).toBe("summarising");

    h.conv.handleEvent({
      type: "summarization_retry_scheduled",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 2000,
    });
    expect(h.conv.state.compactPhase).toBe("provider error, retry 1/3 in 2s");

    h.conv.handleEvent({ type: "summarization_retry_finished" });
    expect(h.conv.state.compactPhase).toBe("writing the summary");

    h.tick(9000);
    h.conv.handleEvent({
      type: "compaction_end",
      result: { estimatedTokensAfter: 14_000 },
      aborted: false,
    });
    h.conv.handleResponse({
      type: "response",
      command: "compact",
      success: true,
      data: { tokensBefore: 120_000, estimatedTokensAfter: 14_000 },
    });

    expect(h.conv.state.compacting).toBe(false);
    expect(h.conv.usage.total).toBe(14_000);
    expect(h.conv.usage.estimated).toBe(true);
    expect(h.of("notice").map((e) => e.text)).toEqual([
      "compacting · 120k tokens · summarising",
      "compacting · 120k tokens · provider error, retry 1/3 in 2s",
      "compacting · 120k tokens · writing the summary",
      "compacted: 120000 → 14000 tokens in 9s",
    ]);
    // A compaction that finished starts no turn of its own, so the readout is
    // asked for here rather than waiting on an agent_settled that never comes.
    expect(h.sent).toEqual([{ type: "get_session_stats" }]);
  });

  test("a post-compaction estimate is not overwritten by a larger stale reading", () => {
    const h = harness();
    h.conv.handleResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { contextUsage: { tokens: 120_000, contextWindow: 131_072 } },
    });
    h.conv.handleEvent({ type: "compaction_start" });
    h.conv.handleEvent({ type: "compaction_end", result: { estimatedTokensAfter: 14_000 } });
    expect(h.conv.usage.total).toBe(14_000);
    h.drain();

    // The pre-compact reading arriving late. pi reports no usage between a
    // compaction and the first answer after it, so this is the OLD number.
    h.conv.handleResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { contextUsage: { tokens: 121_500, contextWindow: 131_072 } },
    });
    expect(h.conv.usage.total).toBe(14_000);
    expect(h.conv.usage.estimated).toBe(true);
    expect(h.of("usage")).toEqual([]);

    // A reading BELOW the threshold is the genuine post-compaction one.
    h.conv.handleResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { contextUsage: { tokens: 15_200, contextWindow: 131_072 } },
    });
    expect(h.conv.usage.total).toBe(15_200);
    expect(h.conv.usage.estimated).toBe(false);

    // ...and once the estimate is gone the guard is gone with it: a large
    // reading after that is a genuinely growing context.
    h.conv.handleResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { contextUsage: { tokens: 130_000, contextWindow: 131_072 } },
    });
    expect(h.conv.usage.total).toBe(130_000);
  });

  test("an aborted compaction says so and asks for nothing", () => {
    const h = harness();
    h.conv.handleEvent({ type: "compaction_start" });
    h.drain();
    h.conv.handleEvent({ type: "compaction_end", aborted: true });
    expect(h.conv.state.compacting).toBe(false);
    expect(h.of("notice").map((e) => e.text)).toEqual(["compaction aborted"]);
    expect(h.sent).toEqual([]);
  });
});

describe("responses that are not conversation", () => {
  test("set_model applies the choice and chases the two readings it staled", () => {
    const h = harness();
    h.conv.handleResponse({
      type: "response",
      command: "set_model",
      success: true,
      data: { provider: "ollama", id: "glm-5.2", name: "GLM 5.2" },
    });
    expect(h.conv.state.model).toBe("glm-5.2");
    expect(h.conv.state.provider).toBe("ollama");
    // Chained off the RESPONSE: responses do not arrive in order, and a
    // get_state queued alongside the setter was observed answering first with
    // the OLD model in it.
    expect(h.sent).toEqual([{ type: "get_available_thinking_levels" }, { type: "get_state" }]);
  });

  test("get_state is the only trustworthy thinking level", () => {
    const h = harness();
    h.conv.handleEvent({ type: "thinking_level_changed", level: "high" });
    expect(h.conv.state.thinkingLevel).toBe("high");
    h.conv.handleResponse({
      type: "response",
      command: "get_state",
      success: true,
      data: {
        model: { provider: "ollama", id: "glm-5.2" },
        thinkingLevel: "medium",
        sessionId: "s1",
        sessionFile: "/tmp/s1.jsonl",
        sessionName: "the rewrite",
      },
    });
    expect(h.conv.state).toMatchObject({
      thinkingLevel: "medium",
      model: "glm-5.2",
      sessionId: "s1",
      sessionFile: "/tmp/s1.jsonl",
      sessionName: "the rewrite",
    });
  });

  test("models and commands become their own host events", () => {
    const h = harness();
    h.conv.handleResponse({
      type: "response",
      command: "get_available_models",
      success: true,
      data: { models: [{ provider: "ollama", id: "glm-5.2", baseUrl: "http://x", cost: {} }] },
    });
    h.conv.handleResponse({
      type: "response",
      command: "get_commands",
      success: true,
      data: { commands: [{ name: "ori-test", description: "a skill", source: "skill" }] },
    });
    expect(h.of("models")[0]!.models).toEqual([
      { provider: "ollama", id: "glm-5.2", name: "glm-5.2" },
    ]);
    expect(h.of("commands")[0]!.commands).toEqual([
      { name: "ori-test", description: "a skill", source: "skill" },
    ]);
  });

  test("an empty get_commands list is a true statement and is applied", () => {
    const h = harness();
    h.conv.handleResponse({
      type: "response",
      command: "get_commands",
      success: true,
      data: { commands: [] },
    });
    // Swallowing this left the last deleted skill in the menu forever.
    expect(h.of("commands")[0]!.commands).toEqual([]);
  });

  test("switch_session chases the transcript only after the ack", () => {
    const h = harness();
    h.conv.handleResponse({ type: "response", command: "switch_session", success: true, data: {} });
    expect(h.sent).toEqual([{ type: "get_entries" }]);

    const seen: unknown[][] = [];
    const conv2 = new Conversation("c2", () => {}, {
      send: () => {},
      onEntries: (entries) => seen.push(entries),
    });
    conv2.handleResponse({
      type: "response",
      command: "get_entries",
      success: true,
      data: { entries: [{ type: "message" }], leafId: "e9" },
    });
    expect(seen).toEqual([[{ type: "message" }]]);
  });
});

describe("snapshot", () => {
  test("hands over a deep copy the caller cannot mutate back into the state", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("a"));
    const snap = h.conv.snapshot();
    if (snap.t !== "snapshot") throw new Error("expected a snapshot");
    expect(snap.turns.map((t) => t.text)).toEqual(["q", "a"]);
    snap.turns[1]!.text = "tampered";
    expect(h.conv.turns[1]!.text).toBe("a");
  });
});
