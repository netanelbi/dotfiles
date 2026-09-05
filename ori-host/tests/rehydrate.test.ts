/**
 * rehydrate.test.ts -- a pi session file back into Turn[].
 *
 * The entry shapes below are the ones a real session file holds, read off
 * `~/.pi/agent/sessions/.../<ts>_<uuid>.jsonl` and cross-checked against
 * `@earendil-works/pi-coding-agent/docs/session-format.md`: an assistant message
 * carries `thinking` / `text` / `toolCall` blocks in one array, a toolCall block
 * is `{type,id,name,arguments}`, and a toolResult is a separate entry keyed by
 * `toolCallId` with an `isError` flag. `bg_process_done` arrives as a
 * `custom_message` entry with no `message` field at all.
 *
 * Pure transform, so nothing here is mocked and nothing is timed -- the deps are
 * a counter and a frozen clock.
 */

import { describe, expect, test } from "bun:test";
import { Conversation } from "../src/conversation";
import { rehydrate, type RehydrateDeps } from "../src/rehydrate";
import { Delivery, type HostEvent, type Turn } from "../src/protocol";

const NOW = 1_700_000_000_000;

function deps(): RehydrateDeps {
  let n = 0;
  return { newId: () => `r${++n}`, now: () => NOW };
}

let seq = 0;
/** A session entry with the tree fields pi writes. Ids are not read by the
 *  transform, but a fixture missing them would not be a real entry. */
function entry(message: unknown, timestamp = "2026-08-30T11:55:00.000Z"): unknown {
  const id = `e${++seq}`;
  return { type: "message", id, parentId: `e${seq - 1}`, timestamp, message };
}

const user = (text: string) => entry({ role: "user", content: [{ type: "text", text }] });

const assistant = (content: unknown[], stopReason = "stop") =>
  entry({
    role: "assistant",
    content,
    provider: "ollama",
    model: "glm-5.3-flash",
    stopReason,
    usage: { input: 1, output: 1, totalTokens: 2 },
  });

const toolResult = (toolCallId: string, out: string, isError = false) =>
  entry({
    role: "toolResult",
    toolCallId,
    toolName: "bash",
    content: [{ type: "text", text: out }],
    isError,
  });

const call = (id: string, name: string, args: Record<string, unknown>) => ({
  type: "toolCall",
  id,
  name,
  arguments: args,
});

/* ------------------------------------------------------------------ *
 * the fold
 * ------------------------------------------------------------------ */

describe("folding a tool loop", () => {
  /**
   * The exchange pi actually records for ONE answer that used tools: assistant,
   * results, assistant, results, assistant. A 1:1 mapping gives five rows of
   * fragments; the panel must see one.
   */
  const entries = [
    { type: "session", version: 3, id: "s1", cwd: "/tmp" },
    { type: "model_change", id: "m1", parentId: null, provider: "ollama", modelId: "glm" },
    user("read my emails"),
    assistant(
      [
        { type: "thinking", thinking: "Check gws first." },
        { type: "text", text: "On it — " },
        call("c1", "bash", { description: "list unread mail", command: "gws gmail list" }),
      ],
      "toolUse",
    ),
    toolResult("c1", "1 unread"),
    assistant([{ type: "text", text: "one from Pavel. " }, call("c2", "bash", { command: "gws gmail read 1" })], "toolUse"),
    toolResult("c2", "boom", true),
    assistant([{ type: "text", text: "Done." }]),
  ];

  test("becomes exactly one user turn and one assistant turn", () => {
    const turns = rehydrate(entries, deps());
    expect(turns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(turns[0]!.text).toBe("read my emails");
    // Every round's prose, in order, in ONE row.
    expect(turns[1]!.text).toBe("On it — one from Pavel. Done.");
    expect(turns[1]!.thinking).toBe("Check gws first.");
  });

  test("the tool calls carry the offset into that turn's text", () => {
    const [, answer] = rehydrate(entries, deps());
    const tools = answer!.tools;
    expect(tools.length).toBe(2);
    // "On it — " had been written when the first call went out; the second came
    // after "one from Pavel. " as well. Slicing the text at those offsets is
    // exactly what the panel does to interleave the rows.
    expect(tools[0]!.at).toBe("On it — ".length);
    expect(tools[1]!.at).toBe("On it — one from Pavel. ".length);
    expect(answer!.text.slice(0, tools[0]!.at)).toBe("On it — ");
    expect(answer!.text.slice(0, tools[1]!.at)).toBe("On it — one from Pavel. ");
  });

  test("each call keeps its identity, summary and result", () => {
    const [, answer] = rehydrate(entries, deps());
    const [first, second] = answer!.tools;
    expect(first!.id).toBe("c1");
    expect(first!.name).toBe("bash");
    // The description the agent wrote beats the mechanical summary; `raw` is
    // what it actually ran.
    expect(first!.summary).toBe("list unread mail");
    expect(first!.raw).toBe("gws gmail list");
    expect(first!.result).toBe("1 unread");
    expect(first!.state).toBe("ok");
    // isError on the RESULT entry, not on the call.
    expect(second!.state).toBe("error");
    expect(second!.result).toBe("boom");
  });

  test("a second question opens a second answer instead of welding", () => {
    const turns = rehydrate(
      [
        user("one"),
        assistant([{ type: "text", text: "first" }]),
        user("two"),
        assistant([{ type: "text", text: "second" }]),
      ],
      deps(),
    );
    expect(turns.map((t) => t.text)).toEqual(["one", "first", "two", "second"]);
  });

  /** The bug the QML comment records: consecutive assistant entries folded
   *  unconditionally welded two answers into one paragraph. Only an entry that
   *  ENDED asking for a tool may continue a row. */
  test("two assistant entries with no tool call between them stay apart", () => {
    const turns = rehydrate(
      [assistant([{ type: "text", text: "HOLD" }]), assistant([{ type: "text", text: "Thought a bit" }])],
      deps(),
    );
    expect(turns.map((t) => t.text)).toEqual(["HOLD", "Thought a bit"]);
  });

  /**
   * A real shape, from entries 93-95 of
   * `2026-08-29T17-13-34-109Z_01a04e83...jsonl`: the provider returned a 524, pi
   * recorded it as an assistant entry with `content: []`, then retried and the
   * answer continued mid-sentence. Letting that empty entry close the fold split
   * one live answer across two rows, the second starting at "The screenshot".
   */
  test("an empty errored round does not close the fold", () => {
    const turns = rehydrate(
      [
        user("why is the tray wrong"),
        assistant([{ type: "text", text: "Let me look. " }, call("c9", "bash", { command: "grim" })], "toolUse"),
        toolResult("c9", "shot taken"),
        assistant([], "error"),
        assistant([{ type: "text", text: "The screenshot settles it." }]),
      ],
      deps(),
    );
    expect(turns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(turns[1]!.text).toBe("Let me look. The screenshot settles it.");
    expect(turns[1]!.tools.length).toBe(1);
  });

  test("every rehydrated turn is settled", () => {
    const turns = rehydrate(entries, deps());
    expect(turns.every((t) => t.pending === false)).toBe(true);
    expect(turns.every((t) => typeof t.settledAt === "number" && t.settledAt! > 0)).toBe(true);
    // The entry's own timestamp, not the clock: a transcript from Tuesday must
    // not read as having just settled.
    expect(turns[0]!.settledAt).toBe(Date.parse("2026-08-30T11:55:00.000Z"));
  });

  test("a question with an answer under it is read; a trailing one is not", () => {
    const turns = rehydrate([user("one"), assistant([{ type: "text", text: "hi" }]), user("two")], deps());
    expect(turns[0]!.delivery).toBe(Delivery.Read);
    expect(turns[2]!.delivery).toBe(Delivery.Sent);
  });
});

/* ------------------------------------------------------------------ *
 * non-content entries
 * ------------------------------------------------------------------ */

describe("entries that are not conversation content", () => {
  test("a bg_process_done with no matching start is nothing, not a crash", () => {
    const turns = rehydrate(
      [
        user("go"),
        {
          type: "custom_message",
          id: "x1",
          parentId: "e0",
          customType: "bg_process_done",
          content: "[SUBAGENT_DONE] general finished",
          display: true,
          details: { pid: 4242 },
        },
        assistant([{ type: "text", text: "done" }]),
      ],
      deps(),
    );
    expect(turns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(turns[1]!.text).toBe("done");
  });

  test("headers, custom state, compactions and labels are skipped", () => {
    const turns = rehydrate(
      [
        { type: "session", version: 3, id: "s", cwd: "/tmp" },
        { type: "custom", id: "c", customType: "session-note", data: { text: "note" } },
        { type: "compaction", id: "k", summary: "earlier", tokensBefore: 50000 },
        { type: "branch_summary", id: "b", fromId: "e1", summary: "branch" },
        { type: "label", id: "l", targetId: "e1", label: "checkpoint" },
        { type: "session_info", id: "i", name: "Refactor auth" },
        { type: "thinking_level_change", id: "t", thinkingLevel: "high" },
        user("still here"),
      ],
      deps(),
    );
    expect(turns.length).toBe(1);
    expect(turns[0]!.text).toBe("still here");
  });

  test("a toolResult whose call is not in the file is dropped", () => {
    const turns = rehydrate([toolResult("gone", "output"), user("hi")], deps());
    expect(turns.map((t) => t.role)).toEqual(["user"]);
  });

  test("an assistant entry with nothing on it is not a blank row", () => {
    const turns = rehydrate(
      [user("hi"), assistant([], "error"), assistant([{ type: "text", text: "real" }])],
      deps(),
    );
    expect(turns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(turns[1]!.text).toBe("real");
  });
});

/* ------------------------------------------------------------------ *
 * torn input
 * ------------------------------------------------------------------ */

describe("torn and invalid entries", () => {
  /** store.readTranscript drops lines that will not parse, but a line that
   *  parses can still be junk -- a truncated write, a `message` that is null, a
   *  content array of numbers. None of it may throw. */
  const junk: unknown[] = [
    null,
    undefined,
    42,
    "not an object",
    [],
    {},
    { type: "message" },
    { type: "message", message: null },
    { type: "message", message: "user" },
    { type: "message", message: { role: "user", content: 42 } },
    { type: "message", message: { role: "assistant", content: [null, 7, { type: "text" }] } },
    { type: "message", message: { role: "assistant", content: [{ type: "toolCall" }] } },
    { type: "message", message: { role: "toolResult", toolCallId: null } },
  ];

  test("skipped without throwing, and the surrounding turns survive", () => {
    const turns = rehydrate(
      [
        user("before"),
        ...junk,
        assistant([{ type: "text", text: "after" }, call("c9", "read", { file_path: "/tmp/x" })], "toolUse"),
        toolResult("c9", "contents"),
        assistant([{ type: "text", text: " and more" }]),
      ],
      deps(),
    );

    // The junk contributed exactly two rows: an empty user turn (a `message`
    // with role user and unreadable content IS still a question that was asked)
    // and a nameless tool call. The junk assistant entry that ended on a
    // toolCall opened the row the real answer then folded into -- which is the
    // fold rule doing its job on input it cannot tell apart from a tool loop.
    expect(turns.map((t) => t.role)).toEqual(["user", "user", "assistant"]);
    expect(turns[0]!.text).toBe("before");
    const answer = turns[2]!;
    expect(answer.text).toBe("after and more");

    const real = answer.tools.find((t) => t.id === "c9");
    expect(real).toBeDefined();
    expect(real!.name).toBe("read");
    expect(real!.at).toBe("after".length);
    expect(real!.result).toBe("contents");
  });

  test("a toolCall block with no id or name still lands, with a minted id", () => {
    const turns = rehydrate(
      [{ type: "message", id: "e", message: { role: "assistant", content: [{ type: "toolCall" }] } }],
      deps(),
    );
    expect(turns.length).toBe(1);
    expect(turns[0]!.tools.length).toBe(1);
    expect(turns[0]!.tools[0]!.name).toBe("tool");
    expect(turns[0]!.tools[0]!.id).toBe("r2"); // r1 was the turn
  });

  test("an entirely junk file yields no turns and no exception", () => {
    expect(rehydrate(junk.filter((x) => !isMessage(x)), deps())).toEqual([]);
    expect(rehydrate([], deps())).toEqual([]);
  });
});

function isMessage(v: unknown): boolean {
  return typeof v === "object" && v !== null && (v as { type?: unknown }).type === "message";
}

/* ------------------------------------------------------------------ *
 * size -- the 120-entry cap is gone
 * ------------------------------------------------------------------ */

test("a transcript far past the old 120-entry cap rehydrates in full", () => {
  const entries: unknown[] = [{ type: "session", version: 3, id: "s", cwd: "/tmp" }];
  const PAIRS = 2600; // 5200 message entries
  for (let i = 0; i < PAIRS; i++) {
    entries.push(user(`question ${i}`));
    entries.push(assistant([{ type: "text", text: `answer ${i}` }]));
  }
  expect(entries.length).toBeGreaterThan(5000);

  const turns = rehydrate(entries, deps());

  // The cap that used to live here kept the last 120 ENTRIES, which would have
  // produced 120 turns and silently thrown the rest of the conversation away.
  expect(turns.length).toBe(PAIRS * 2);
  expect(turns[0]!.text).toBe("question 0");
  expect(turns[1]!.text).toBe("answer 0");
  expect(turns[turns.length - 1]!.text).toBe(`answer ${PAIRS - 1}`);
  expect(new Set(turns.map((t) => t.id)).size).toBe(turns.length);
});

/* ------------------------------------------------------------------ *
 * installing into a conversation
 * ------------------------------------------------------------------ */

describe("Conversation.install", () => {
  function harness() {
    const events: HostEvent[] = [];
    let n = 0;
    const conv = new Conversation("c1", (e) => events.push(e), {
      now: () => NOW,
      newId: () => `t${++n}`,
      send: () => {},
    });
    return { conv, events };
  }

  const restored = (): Turn[] =>
    rehydrate([user("old question"), assistant([{ type: "text", text: "old answer" }])], deps());

  test("a rehydrated conversation is not busy and has no pending turn", () => {
    const { conv, events } = harness();
    // Leave it mid-turn: busy, with a pending assistant row waiting for tokens.
    conv.ask("mid-flight");
    expect(conv.state.busy).toBe(true);
    expect(conv.turns.some((t) => t.pending)).toBe(true);

    events.length = 0;
    conv.install(restored());

    expect(conv.state.busy).toBe(false);
    expect(conv.state.compacting).toBe(false);
    expect(conv.turns.some((t) => t.pending)).toBe(false);
    expect(conv.turns.map((t) => t.text)).toEqual(["old question", "old answer"]);
  });

  test("it announces itself as exactly one snapshot", () => {
    const { conv, events } = harness();
    conv.install(restored());
    expect(events.length).toBe(1);
    const snap = events[0]!;
    expect(snap.t).toBe("snapshot");
    if (snap.t !== "snapshot") throw new Error("unreachable");
    expect(snap.convId).toBe("c1");
    expect(snap.state.busy).toBe(false);
    expect(snap.turns.map((t) => t.text)).toEqual(["old question", "old answer"]);
    // Cloned on the way out: the panel's copy must not alias the host's.
    expect(snap.turns[0]).not.toBe(conv.turns[0]);
  });

  /** The reason install resets `liveId`: the next answer must open its own row
   *  rather than stream into one that came off a file. */
  test("the next question streams into a new turn, not into a restored one", () => {
    const { conv } = harness();
    conv.install(restored());
    const { steer } = conv.ask("next");
    // Not busy after install, so this is a prompt and not a steer.
    expect(steer).toBe(false);
    conv.handleEvent({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "new answer" },
    });
    expect(conv.turns.map((t) => t.text)).toEqual(["old question", "old answer", "next", "new answer"]);
  });
});
