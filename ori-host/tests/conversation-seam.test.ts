/**
 * conversation-seam.test.ts -- the steer seam, which is where the old code's
 * worst bug lived and where it was fixed three times before the boundary was
 * finally read off the wire instead of guessed at.
 *
 * The sequence every test here replays is the live capture recorded in
 * PiSession.qml:1030-1050:
 *
 *   10.73 >> steer                      accepted immediately
 *   ...   8.2s of deltas, ALL of them the OLD answer ...
 *   18.92 << message_end role=assistant  the interrupted answer, complete
 *   18.92 << turn_end
 *   18.92 << turn_start                  pi opens a NEW TURN
 *   18.92 << message_end role=user       pi echoes the steer back   <-- THE SEAM
 *   18.92 << message_start               the redirected answer begins
 *   20.24 << turn_end / agent_end / agent_settled   ONCE, across both
 *
 * pi merges nothing: it finishes the answer, ends the turn and opens another.
 * The echo is the only honest discriminator -- see the stopReason test below.
 */

import { describe, expect, test } from "bun:test";
import { Conversation, type PiEvent } from "../src/conversation";
import type { HostEvent, Turn } from "../src/protocol";

function harness(start = 1_000_000) {
  const events: HostEvent[] = [];
  let clock = start;
  let n = 0;
  const conv = new Conversation("c1", (e) => events.push(e), {
    now: () => clock,
    newId: () => `t${++n}`,
    send: () => {},
  });
  return {
    conv,
    events,
    tick: (ms: number) => {
      clock += ms;
    },
    of: <T extends HostEvent["t"]>(t: T) =>
      events.filter((e) => e.t === t) as Array<Extract<HostEvent, { t: T }>>,
    drain: () => events.splice(0, events.length),
  };
}

const textDelta = (delta: string): PiEvent => ({
  type: "message_update",
  assistantMessageEvent: { type: "text_delta", delta },
});

/** pi echoing a user message back: "I have taken this off the queue and put it
 *  in the conversation". */
const echo = (text: string): PiEvent => ({
  type: "message_end",
  message: { role: "user", content: [{ type: "text", text }] },
});

const assistantEnd = (text: string, stopReason: string): PiEvent => ({
  type: "message_end",
  message: { role: "assistant", content: [{ type: "text", text }], stopReason },
});

const shape = (turns: readonly Turn[]) => turns.map((t) => [t.role, t.text]);

describe("steer mid-text", () => {
  test("splits at the echo and keeps the partial answer under its own question", () => {
    const h = harness();
    h.conv.ask("write exactly 900 words about the anchor");
    h.conv.handleEvent({ type: "message_start", message: { role: "assistant" } });
    h.conv.handleEvent(textDelta("Anchors have always held "));

    // The steer goes out while the old answer is still streaming. ONLY THE
    // QUESTION is appended: nothing has changed about the answer in flight.
    const { steer } = h.conv.ask("STOP. forget the anchor. reply FIRSTSTEER");
    expect(steer).toBe(true);
    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words about the anchor"],
      ["assistant", "Anchors have always held "],
      ["user", "STOP. forget the anchor. reply FIRSTSTEER"],
    ]);

    // ...and more of the OLD answer arrives, which must land on the assistant
    // turn ABOVE the new question, not on the end of the list.
    h.conv.handleEvent(textDelta("everything."));
    expect(h.conv.turns[1]!.text).toBe("Anchors have always held everything.");
    h.tick(8200);
    h.drain();

    h.conv.handleEvent(assistantEnd("Anchors have always held everything.", "stop"));
    h.conv.handleEvent(echo("STOP. forget the anchor. reply FIRSTSTEER"));
    h.conv.handleEvent({ type: "message_start", message: { role: "assistant" } });
    h.conv.handleEvent(textDelta("FIRSTSTEER"));

    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words about the anchor"],
      ["assistant", "Anchors have always held everything."],
      ["user", "STOP. forget the anchor. reply FIRSTSTEER"],
      ["assistant", "FIRSTSTEER"],
    ]);

    // The interrupted answer is CLOSED and PAID -- `busy` spans both turns, so
    // billing only on the busy edge would leave it with no receipt at all.
    const interrupted = h.conv.turns[1]!;
    expect(interrupted.pending).toBe(false);
    expect(interrupted.cost).toBeDefined();
    expect(h.conv.turns[3]!.pending).toBe(true);

    // The redirect appended at the END, so no index is carried.
    expect(h.of("turn_add").map((e) => [e.turn.id, e.index])).toEqual([["t4", undefined]]);
    expect(h.of("turn_drop")).toEqual([]);
  });

  test("the second receipt measures the redirect, not the whole request", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent({ type: "message_update", usage: { input: 50, output: 0, totalTokens: 50 } });
    h.conv.handleEvent(textDelta("old"));
    h.conv.ask("steer");
    h.tick(10_000);
    h.conv.handleEvent({
      type: "message_update",
      usage: { input: 50, output: 400, totalTokens: 450 },
    });
    h.conv.handleEvent(echo("steer"));

    expect(h.conv.turns[1]!.cost!.seconds).toBe(10);
    expect(h.conv.turns[1]!.cost!.output).toBe(400);

    // The clock and the token baseline restart with the answer they describe.
    h.tick(2000);
    h.conv.handleEvent(textDelta("new"));
    h.conv.handleEvent({
      type: "message_update",
      usage: { input: 50, output: 430, totalTokens: 480 },
    });
    h.conv.handleEvent({ type: "agent_settled" });
    expect(h.conv.turns[3]!.cost!.seconds).toBe(2);
    expect(h.conv.turns[3]!.cost!.output).toBe(30);
  });
});

describe("steer mid-tool-call", () => {
  test("splits even though the preceding stopReason is toolUse", () => {
    const h = harness();
    h.conv.ask("build and test it");
    h.conv.handleEvent(textDelta("Running the build. "));
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "bash",
      args: { command: "bun run build" },
    });

    const { steer } = h.conv.ask("stop, just tell me the version");
    expect(steer).toBe(true);

    // pi holds the steer until the call in flight RETURNS.
    h.conv.handleEvent({
      type: "tool_execution_end",
      toolCallId: "tc1",
      result: { content: [{ type: "text", text: "built" }] },
      isError: false,
    });
    h.drain();

    // THE REFUTED DISCRIMINATOR. The message_end immediately before the seam
    // carries stopReason "toolUse", so any rule keyed on stopReason either
    // splits here for the wrong reason or refuses to split at all. Only the
    // role-user echo is a statement about the queue.
    h.conv.handleEvent(assistantEnd("Running the build. ", "toolUse"));
    expect(h.of("turn_add")).toEqual([]); // nothing has split yet

    h.conv.handleEvent(echo("stop, just tell me the version"));
    h.conv.handleEvent(textDelta("0.1.0"));

    expect(shape(h.conv.turns)).toEqual([
      ["user", "build and test it"],
      ["assistant", "Running the build. "],
      ["user", "stop, just tell me the version"],
      ["assistant", "0.1.0"],
    ]);
    // The call stays on the answer that made it: the tool row rides the same
    // turn the text does.
    expect(h.conv.turns[1]!.tools.map((x) => x.id)).toEqual(["tc1"]);
    expect(h.conv.turns[3]!.tools).toEqual([]);
  });

  test("a toolUse message_end on its own never splits anything", () => {
    const h = harness();
    h.conv.ask("build it");
    h.conv.handleEvent(textDelta("Running. "));
    h.drain();
    // An ordinary tool-using turn: no steer outstanding, several message_end
    // frames with stopReason toolUse, one answer.
    h.conv.handleEvent(assistantEnd("Running. ", "toolUse"));
    h.conv.handleEvent(textDelta("Done."));
    h.conv.handleEvent(assistantEnd("Running. Done.", "stop"));
    expect(shape(h.conv.turns)).toEqual([
      ["user", "build it"],
      ["assistant", "Running. Done."],
    ]);
    expect(h.of("turn_add")).toEqual([]);
    expect(h.of("turn_drop")).toEqual([]);
  });
});

describe("steer against a turn with no content", () => {
  test("drops the empty turn instead of leaving a blank row", () => {
    const h = harness();
    h.conv.ask("q");
    // Steer before a single token, a single reasoning character or one call.
    h.conv.ask("actually, never mind -- do this instead");
    const emptyId = h.conv.turns[1]!.id;
    h.drain();

    h.conv.handleEvent(echo("actually, never mind -- do this instead"));

    expect(h.of("turn_drop").map((e) => e.turnId)).toEqual([emptyId]);
    expect(shape(h.conv.turns)).toEqual([
      ["user", "q"],
      ["user", "actually, never mind -- do this instead"],
      ["assistant", ""],
    ]);
    // No receipt for a turn that produced nothing -- a bare "0.4s" floating
    // between two turns is the artefact this guards.
    expect(h.conv.turns.every((t) => t.cost === undefined)).toBe(true);
  });

  test("a turn carrying ONLY reasoning is kept, not dropped", () => {
    const h = harness();
    h.conv.ask("write exactly 900 words");
    // Measured: 117 SECONDS of thinking_delta before the first text_delta. A
    // steer landing in that window closes a turn carrying nothing but
    // reasoning, which the panel does draw.
    h.conv.handleEvent({
      type: "message_update",
      assistantMessageEvent: { type: "thinking_delta", delta: "weighing the structure" },
    });
    h.conv.ask("stop");
    h.drain();
    h.conv.handleEvent(echo("stop"));

    expect(h.of("turn_drop")).toEqual([]);
    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words"],
      ["assistant", ""],
      ["user", "stop"],
      ["assistant", ""],
    ]);
    expect(h.conv.turns[1]!.thinking).toBe("weighing the structure");
  });

  test("a turn carrying ONLY a tool call is kept, not dropped", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent({
      type: "tool_execution_start",
      toolCallId: "tc1",
      toolName: "bash",
      args: { command: "sleep 600" },
    });
    h.conv.ask("stop");
    h.drain();
    h.conv.handleEvent(echo("stop"));
    expect(h.of("turn_drop")).toEqual([]);
    expect(h.conv.turns.map((t) => t.role)).toEqual(["user", "assistant", "user", "assistant"]);
  });
});

describe("two steers queued", () => {
  test("are matched in order and each answer files under its own question", () => {
    const h = harness();
    h.conv.ask("write exactly 900 words about the anchor");
    h.conv.handleEvent(textDelta("Anchors have always held everything."));
    h.conv.ask("STOP. forget the anchor. reply FIRSTSTEER");
    h.tick(1500);
    h.conv.ask("no, ignore that. reply SECONDSTEER");

    // Five rows, ONE assistant turn so far. The single-slot version of the
    // queue lost the first steer here: the second overwrote the slot, pi echoed
    // the first, the match failed, and FIRSTSTEER welded onto the tail of the
    // essay under the anchor question.
    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words about the anchor"],
      ["assistant", "Anchors have always held everything."],
      ["user", "STOP. forget the anchor. reply FIRSTSTEER"],
      ["user", "no, ignore that. reply SECONDSTEER"],
    ]);
    h.drain();

    // pi answers them one at a time, so the FIRST seam inserts in the middle.
    h.conv.handleEvent(echo("STOP. forget the anchor. reply FIRSTSTEER"));
    h.conv.handleEvent(textDelta("FIRSTSTEER"));
    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words about the anchor"],
      ["assistant", "Anchors have always held everything."],
      ["user", "STOP. forget the anchor. reply FIRSTSTEER"],
      ["assistant", "FIRSTSTEER"],
      ["user", "no, ignore that. reply SECONDSTEER"],
    ]);
    // Inserted UNDER ITS OWN QUESTION at index 3, not appended at 4 -- which
    // would have filed steer 1's reply under steer 2.
    expect(h.of("turn_add").map((e) => e.index)).toEqual([3]);

    h.conv.handleEvent(echo("no, ignore that. reply SECONDSTEER"));
    h.conv.handleEvent(textDelta("SECONDSTEER"));
    h.conv.handleEvent({ type: "agent_settled" });

    expect(shape(h.conv.turns)).toEqual([
      ["user", "write exactly 900 words about the anchor"],
      ["assistant", "Anchors have always held everything."],
      ["user", "STOP. forget the anchor. reply FIRSTSTEER"],
      ["assistant", "FIRSTSTEER"],
      ["user", "no, ignore that. reply SECONDSTEER"],
      ["assistant", "SECONDSTEER"],
    ]);
    // No ids were reused and none were re-keyed: an insert costs nothing here,
    // which is the whole reason shiftRowKeys() does not exist.
    expect(new Set(h.conv.turns.map((t) => t.id)).size).toBe(6);
    expect(h.of("notice")).toEqual([]);
  });

  test("out-of-order echoes are consumed by position, and duplicates are legal", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("old"));
    h.conv.ask("again");
    h.conv.ask("again"); // the SAME text twice -- both are real messages
    h.drain();

    h.conv.handleEvent(echo("again"));
    h.conv.handleEvent(textDelta("one"));
    // The first echo consumed the first queue slot, so a second identical echo
    // still matches -- a queue that popped by value alone would be empty here.
    h.conv.handleEvent(echo("again"));
    h.conv.handleEvent(textDelta("two"));

    expect(shape(h.conv.turns)).toEqual([
      ["user", "q"],
      ["assistant", "old"],
      ["user", "again"],
      ["assistant", "one"],
      ["user", "again"],
      ["assistant", "two"],
    ]);
    // Searched from the END, so the second echo resolved to the most recent
    // copy of the question rather than the first.
    expect(h.of("turn_add").map((e) => e.index)).toEqual([3, undefined]);
  });
});

describe("echoes that are not seams", () => {
  test("an ordinary turn's own question echo splits nothing", () => {
    const h = harness();
    h.conv.ask("hello");
    h.conv.handleEvent(textDelta("hi"));
    h.drain();
    // Every prompt is echoed back too; it is in no one's queue, so a stale
    // entry cannot split anything.
    h.conv.handleEvent(echo("hello"));
    expect(h.of("turn_add")).toEqual([]);
    expect(shape(h.conv.turns)).toEqual([
      ["user", "hello"],
      ["assistant", "hi"],
    ]);
  });

  test("a mismatched echo falls through rather than splitting at the wrong place", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("old"));
    h.conv.ask("  steer with space  ");
    h.drain();
    // Matched EXACTLY, not trimmed: trimming this end could only hide a genuine
    // mismatch, and a mismatch has to fall through.
    h.conv.handleEvent(echo("steer with space"));
    expect(h.of("turn_add")).toEqual([]);
    expect(h.conv.turns.length).toBe(3);
  });

  test("a steer that never reached its boundary is reported, not silently dropped", () => {
    const h = harness();
    h.conv.ask("q");
    h.conv.handleEvent(textDelta("old"));
    h.conv.ask("steer that dies with the turn");
    h.drain();

    h.conv.handleEvent({ type: "agent_settled" });
    expect(h.of("notice").map((e) => e.text)).toEqual([
      "that steer never got an answer -- the turn ended first",
    ]);
    // ...and the queue is empty, so the NEXT question's turn cannot be split by
    // the corpse of this one.
    h.conv.ask("a fresh question");
    h.drain();
    h.conv.handleEvent(echo("steer that dies with the turn"));
    expect(h.of("turn_add")).toEqual([]);
  });
});
