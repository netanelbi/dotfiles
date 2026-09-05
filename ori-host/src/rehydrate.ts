/**
 * rehydrate.ts -- a pi session file, back into the panel's `Turn[]`.
 *
 * A conversation that is only on disk draws as an EMPTY transcript until the
 * next question, because nothing maps pi's session entries onto turns. This is
 * that map. It is a pure data transform: no fs, no net, no child -- store.ts
 * does the reading, main.ts does the wiring, and this file only ever sees an
 * array of already-parsed values.
 *
 * The one rule that decides whether a restored transcript looks like the live
 * one or like a protocol dump: **FOLD A TOOL LOOP INTO ONE ASSISTANT TURN.**
 * pi records a single logical answer as several assistant messages with
 * toolResult entries between them, whereas the live path (conversation.ts)
 * builds exactly ONE assistant turn per question and stamps each tool call with
 * the character offset it interrupted the prose at. Mapping entries 1:1 would
 * produce a wall of fragment rows -- the single most visible rendering bug
 * available here.
 *
 * What continues a row is narrow, and deliberately so (PiSession.qml:1815-1827):
 * only an assistant entry that ENDED asking for a tool. Consecutive assistant
 * entries were once folded unconditionally, on the grounds that a tool loop
 * records itself that way -- true, but so does a session file two clients
 * appended to, and the result was one answer welded to the front of the next.
 *
 * Entry shapes are pi's, documented in
 * `@earendil-works/pi-coding-agent/docs/session-format.md`. They are narrowed by
 * runtime guards rather than typed: every value here arrives as `unknown` off a
 * file that another process is still appending to, and pi's own declarations are
 * the only legitimate source for those shapes (rule 3) -- a rival copy in this
 * file would be exactly the second parser the rewrite exists to delete.
 *
 * Entries form a TREE via id/parentId, and this walks the file IN ORDER rather
 * than following the leaf's branch. For sessions this panel can produce that is
 * the same walk: branching needs pi's `/tree` or `/fork`, neither of which the
 * panel exposes. When a branch does exist, pi's own `get_entries` answers with
 * the branch and a leafId, and that path is already wired
 * (ConversationDeps.onEntries).
 */

import { hasContent, rawArgs, summarizeArgs, tail, TOOL_RESULT_CAP } from "./conversation";
import { Delivery, type ToolCall, type Turn } from "./protocol";

/** The two side effects a pure transform still needs. `now` is only a fallback:
 *  pi stamps every entry, and the entry's own time is the better answer. */
export interface RehydrateDeps {
  newId(): string;
  now(): number;
}

/**
 * Session entries in, turns out. Never throws: an entry that is torn, truncated
 * or simply not conversation content is skipped, because one bad line in a 9 MB
 * transcript must not cost the whole conversation.
 */
export function rehydrate(entries: readonly unknown[], deps: RehydrateDeps): Turn[] {
  const turns: Turn[] = [];
  /** Every tool call seen so far, so a toolResult entry can find its call
   *  without a scan -- they are adjacent in practice but not guaranteed to be. */
  const calls = new Map<string, ToolCall>();
  /** The assistant turn a tool loop is still filling, or null for "the next
   *  assistant entry opens a new one". Tracked rather than searched: several
   *  answers in a row leave older assistant turns in place, and a search for
   *  "the last assistant turn" finds the wrong one and welds three answers into
   *  one paragraph. */
  let open: Turn | null = null;

  for (const entry of entries) {
    const e = record(entry);
    // Everything that is not a message: the session header, model_change,
    // thinking_level_change, compaction, branch_summary, label, session_info,
    // custom (extension state) and custom_message -- which is how a
    // `bg_process_done` with no matching start arrives, and it is nothing here
    // rather than a crash. Torn junk lands here too.
    if (!e || e["type"] !== "message") continue;
    const m = record(e["message"]);
    if (!m) continue;
    const at = stamp(e["timestamp"], deps);

    switch (m["role"]) {
      case "user": {
        // A question always ends the answer above it, tool loop or not.
        open = null;
        // Attached images do NOT come back. The file holds base64 data, while
        // `ImageRef` is a path contract -- materialising one would be a
        // filesystem write from a module that must stay pure, and handing the
        // panel an empty path draws a broken image.
        const t = blank(deps.newId(), "user", at);
        t.text = textOf(m["content"]);
        turns.push(t);
        break;
      }

      case "assistant": {
        const turn: Turn = open ?? push(turns, blank(deps.newId(), "assistant", at));
        turn.settledAt = at;
        let calledTool = false;
        const content = blocks(m["content"]);
        for (const block of content) {
          const b = record(block);
          if (!b) continue;
          if (b["type"] === "text") turn.text += text(b["text"]);
          else if (b["type"] === "thinking") turn.thinking += text(b["thinking"]);
          else if (b["type"] === "toolCall") {
            const call: ToolCall = {
              id: text(b["id"]) || deps.newId(),
              name: text(b["name"]) || "tool",
              summary: summarizeArgs(b["arguments"]),
              raw: rawArgs(b["arguments"]),
              // Nothing in a file is still running. A call whose result never
              // landed (the turn was aborted, or the process died under it) is
              // shown as finished rather than as a spinner that never stops.
              state: "ok",
              // A session file records what a tool was asked to do, not when --
              // but it does record WHERE: entries are in the order they
              // happened, and the text blocks either side of this one are
              // already folded in, so the running length is the same offset the
              // live path stamps. That is what makes a restored turn interleave
              // exactly like a live one.
              at: turn.text.length,
            };
            turn.tools.push(call);
            calls.set(call.id, call);
            calledTool = true;
          }
        }
        // Only an entry that carried something may decide the fold. pi records a
        // transient provider failure as an assistant entry with `content: []`
        // and `stopReason:"error"`, then RETRIES inside the same logical turn --
        // measured in a real session, where the retry resumed mid-sentence. An
        // empty entry is not an answer, so it must not end one; the live path
        // keeps the whole exchange in one turn until agent_settled.
        if (content.length > 0) open = calledTool ? turn : null;
        break;
      }

      case "toolResult": {
        const call = calls.get(text(m["toolCallId"]));
        // A result whose call is not in this file -- a truncated head, a torn
        // assistant entry -- has nothing to attach to.
        if (!call) break;
        if (m["isError"] === true) call.state = "error";
        const out = tail(textOf(m["content"]), TOOL_RESULT_CAP);
        if (out !== "") call.result = out;
        break;
      }

      // bashExecution, custom, branchSummary, compactionSummary: real messages,
      // but not this conversation's content.
      default:
        break;
    }
  }

  // An assistant entry can carry nothing at all (an errored round, a message
  // whose only block was an image). The live path drops such a turn at the seam
  // for the same reason: it draws as a blank band. User turns are kept
  // regardless -- they are the skeleton of the conversation and its label.
  const out = turns.filter((t) => t.role === "user" || hasContent(t));

  // A trailing question with no answer under it is the one message here nothing
  // came back for, so it is the one that cannot claim a read receipt.
  const lastTurn = out[out.length - 1];
  if (lastTurn && lastTurn.role === "user") lastTurn.delivery = Delivery.Sent;

  return out;
}

/* ------------------------------------------------------------------ *
 * guards -- every one of these takes `unknown` and cannot throw
 * ------------------------------------------------------------------ */

function record(v: unknown): Record<string, unknown> | null {
  return typeof v === "object" && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

/** pi's content is either a bare string or a block list (session-format.md), so
 *  the string case is normalised into the list one and there is a single walk. */
function blocks(content: unknown): unknown[] {
  if (typeof content === "string") return [{ type: "text", text: content }];
  return Array.isArray(content) ? content : [];
}

function textOf(content: unknown): string {
  let out = "";
  for (const block of blocks(content)) {
    const b = record(block);
    if (b && b["type"] === "text") out += text(b["text"]);
  }
  return out;
}

/** The entry's own ISO timestamp IS when that turn stopped changing. Falling
 *  back to `now` would date a transcript from Tuesday as having just settled. */
function stamp(v: unknown, deps: RehydrateDeps): number {
  const ms = typeof v === "string" ? Date.parse(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(ms) ? ms : deps.now();
}

function blank(id: string, role: Turn["role"], settledAt: number): Turn {
  return {
    id,
    role,
    text: "",
    thinking: "",
    tools: [],
    images: [],
    // Everything read off disk is history: settled, and never the live sink.
    pending: false,
    // The answer below a question is proof the model read it; the one case that
    // is not true of is corrected above.
    delivery: Delivery.Read,
    settledAt,
  };
}

function push(turns: Turn[], t: Turn): Turn {
  turns.push(t);
  return t;
}
