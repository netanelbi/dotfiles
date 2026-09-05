import { describe, expect, test, afterEach } from "bun:test";
import { mkdtempSync, rmSync, appendFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Store, deriveLabel, readTranscript, summarise, LABEL_MAX } from "../src/store";

const tmps: string[] = [];
function scratch(): string {
  const d = mkdtempSync(join(tmpdir(), "ori-store-"));
  tmps.push(d);
  return d;
}
afterEach(() => {
  while (tmps.length) rmSync(tmps.pop()!, { recursive: true, force: true });
});

const row = (id: string, at: number, over: Partial<{ file: string; label: string; turns: number }> = {}) => ({
  id,
  file: over.file ?? `/s/${id}.jsonl`,
  label: over.label ?? `label ${id}`,
  at,
  turns: over.turns ?? 1,
});

describe("Store", () => {
  test("upsert is idempotent and updates in place", () => {
    const s = new Store();
    s.upsert(row("aaa", 100));
    s.upsert(row("aaa", 100));
    s.upsert(row("aaa", 100));
    expect(s.list()).toHaveLength(1);

    s.upsert(row("aaa", 200, { label: "renamed", turns: 7 }));
    expect(s.list()).toHaveLength(1);
    expect(s.list()[0]).toMatchObject({ id: "aaa", at: 200, label: "renamed", turns: 7 });
    s.close();
  });

  test("upsert does not clobber a read cursor it was not told about", () => {
    const s = new Store();
    s.upsert(row("aaa", 100, {}));
    s.setOffset("aaa", 4096);
    s.upsert(row("aaa", 200)); // a settled turn -- says nothing about the cursor
    expect(s.byId("aaa")?.readOffset).toBe(4096);
    s.close();
  });

  test("list is newest-first and honours the limit", () => {
    const s = new Store();
    s.upsert(row("old", 100));
    s.upsert(row("new", 300));
    s.upsert(row("mid", 200));
    expect(s.list().map((r) => r.id)).toEqual(["new", "mid", "old"]);
    expect(s.list(2).map((r) => r.id)).toEqual(["new", "mid"]);
    s.close();
  });

  test("upsertMany writes a batch in one transaction", () => {
    const s = new Store();
    s.upsertMany([row("a", 1), row("b", 2), row("c", 3)]);
    expect(s.list().map((r) => r.id)).toEqual(["c", "b", "a"]);
    s.close();
  });

  test("byId resolves a full id and a unique prefix", () => {
    const s = new Store();
    s.upsert(row("01a05285-bf63-7fcd-a3fc-2edd7fcf406c", 100));
    s.upsert(row("019df1a6-1417-74ae-9b2a-2cef48893e64", 200));

    expect(s.byId("01a05285-bf63-7fcd-a3fc-2edd7fcf406c")?.at).toBe(100);
    expect(s.byId("01a05285")?.id).toBe("01a05285-bf63-7fcd-a3fc-2edd7fcf406c");
    expect(s.byId("019df1a6")?.id).toBe("019df1a6-1417-74ae-9b2a-2cef48893e64");
    expect(s.byId("nope")).toBeNull();
    expect(s.byId("")).toBeNull();
    s.close();
  });

  test("byId REFUSES an ambiguous prefix instead of picking the newest", () => {
    const s = new Store();
    // Two real pi ids that share their first 8 characters. Before disk
    // discovery the index held only Ori's own sessions and this was rare;
    // with 207 sessions in one workdir it is ordinary, and the old
    // `ORDER BY at DESC LIMIT 1` silently opened whichever was newer.
    s.upsert(row("01a05285-bf63-7fcd-a3fc-2edd7fcf406c", 100));
    s.upsert(row("01a05285-0000-4000-8000-000000000000", 900));

    expect(s.byId("01a05285")).toBeNull();
    expect(s.ambiguous("01a05285")).toBe(true);

    // One more character disambiguates, and then it resolves again.
    expect(s.byId("01a05285-b")?.at).toBe(100);
    expect(s.ambiguous("01a05285-b")).toBe(false);

    // A prefix matching nothing is NOT ambiguous -- the caller words those
    // two failures differently, so they must stay distinguishable.
    expect(s.byId("zzzz")).toBeNull();
    expect(s.ambiguous("zzzz")).toBe(false);
    s.close();
  });

  test("byId prefers an exact hit over a prefix hit", () => {
    const s = new Store();
    // "ab" is both a full id and a prefix of the newer "abcd".
    s.upsert(row("ab", 100));
    s.upsert(row("abcd", 900));
    expect(s.byId("ab")?.id).toBe("ab");
    s.close();
  });

  test("survives a real file and reopen", () => {
    const dir = scratch();
    const path = join(dir, "index.db");
    const a = new Store(path);
    a.upsert(row("keep", 42));
    a.setMeta("legacyIndexMigrated", "1");
    a.close();

    const b = new Store(path);
    expect(b.byId("keep")?.at).toBe(42);
    // The migration marker outlives the process, which is what "migrate once"
    // means.
    expect(b.meta("legacyIndexMigrated")).toBe("1");
    b.close();
  });

  test("seed inserts what is missing and only fills gaps in what is not", () => {
    const s = new Store();
    // Nothing there yet: a scanned row is inserted whole.
    s.seed([{ id: "new", file: "/s/new.jsonl", label: "scanned", at: 100, turns: 0 }]);
    expect(s.byId("new")).toMatchObject({ label: "scanned", at: 100, turns: 0 });

    // A row a settled turn wrote. Every column of it is better than a scan's.
    s.upsert(row("live", 500, { label: "the real label", turns: 12 }));
    s.seed([{ id: "live", file: "/s/live.jsonl", label: "scanned", at: 400, turns: 0 }]);
    expect(s.byId("live")).toMatchObject({ label: "the real label", at: 500, turns: 12 });

    // Except the path, where the filesystem is authoritative, and recency, which
    // only ever moves forward.
    s.seed([{ id: "live", file: "/moved/live.jsonl", label: "", at: 900, turns: 0 }]);
    expect(s.byId("live")).toMatchObject({ file: "/moved/live.jsonl", at: 900, turns: 12 });

    // A blank label IS a gap, and a scan may fill it.
    s.upsert({ id: "blank", file: "/s/b.jsonl", label: "", at: 1, turns: 0 });
    s.seed([{ id: "blank", file: "/s/b.jsonl", label: "found it", at: 1, turns: 0 }]);
    expect(s.byId("blank")?.label).toBe("found it");
    s.close();
  });

  test("meta is null until set", () => {
    const s = new Store();
    expect(s.meta("nope")).toBeNull();
    s.setMeta("k", "a");
    s.setMeta("k", "b");
    expect(s.meta("k")).toBe("b");
    s.close();
  });
});

describe("deriveLabel", () => {
  test("collapses whitespace and trims", () => {
    expect(deriveLabel("  read   my\n\temails  please ")).toBe("read my emails please");
  });

  test("truncates at 90 chars with an ellipsis", () => {
    const long = "x".repeat(200);
    const out = deriveLabel(long);
    expect(out).toBe("x".repeat(LABEL_MAX) + "…");
    // 90 characters plus the one-character ellipsis.
    expect(out).toHaveLength(91);
    expect(LABEL_MAX).toBe(90);
  });

  test("a 90-char label is not truncated", () => {
    const exact = "y".repeat(90);
    expect(deriveLabel(exact)).toBe(exact);
    expect(deriveLabel("z".repeat(91))).toBe("z".repeat(90) + "…");
  });
});

/* ------------------------------------------------------------------ *
 * Transcript reading
 * ------------------------------------------------------------------ */

/** A file shaped like a pi session JSONL: header, then N user/assistant pairs. */
function writeTranscript(path: string, pairs: number, firstAsk: string): number {
  const lines: string[] = [
    JSON.stringify({ type: "session", version: 3, id: "sid", timestamp: "t", cwd: "/tmp" }),
  ];
  for (let i = 0; i < pairs; i++) {
    lines.push(
      JSON.stringify({
        type: "message",
        id: `u${i}`,
        parentId: null,
        timestamp: "t",
        message: { role: "user", content: [{ type: "text", text: i === 0 ? firstAsk : `ask ${i}` }] },
      }),
    );
    lines.push(
      JSON.stringify({
        type: "message",
        id: `a${i}`,
        parentId: `u${i}`,
        timestamp: "t",
        message: { role: "assistant", content: [{ type: "text", text: `answer ${i}` }] },
      }),
    );
  }
  writeFileSync(path, lines.join("\n") + "\n");
  return lines.length;
}

/**
 * Replace Bun.file with a recording proxy, so a test can assert HOW the file was
 * read -- not just what came back. `.text()` / `.bytes()` / `.arrayBuffer()`
 * would all slurp the whole 9 MB the old code slurped.
 */
function recordFileAccess(): { calls: string[]; restore: () => void } {
  const calls: string[] = [];
  const real = Bun.file;
  const patched = ((...args: Parameters<typeof Bun.file>) => {
    const f = real(...args);
    return new Proxy(f, {
      get(target, prop, recv) {
        calls.push(String(prop));
        const v = Reflect.get(target, prop, recv);
        return typeof v === "function" ? v.bind(target) : v;
      },
    });
  }) as typeof Bun.file;
  (Bun as { file: typeof Bun.file }).file = patched;
  return { calls, restore: () => ((Bun as { file: typeof Bun.file }).file = real) };
}

describe("readTranscript", () => {
  test("reads a >5000-line transcript by streaming, with NO 120-entry cap", async () => {
    const dir = scratch();
    const path = join(dir, "big.jsonl");
    // 2600 pairs -> 5201 lines, comfortably past the old 120-entry cap and past
    // any single stream chunk.
    const lines = writeTranscript(path, 2600, "the opening question");
    expect(lines).toBe(5201);

    const rec = recordFileAccess();
    let read;
    try {
      read = await readTranscript(path);
    } finally {
      rec.restore();
    }

    // No cap: every line came back.
    expect(read.entries).toHaveLength(5201);
    expect(read.torn).toBe(0);

    // And it was STREAMED: stream() was used, and none of the slurping
    // accessors were touched.
    expect(rec.calls).toContain("stream");
    for (const slurp of ["text", "bytes", "arrayBuffer", "json", "formData"]) {
      expect(rec.calls).not.toContain(slurp);
    }

    // The offset is the whole file, so a re-read costs nothing.
    expect(read.offset).toBe(Bun.file(path).size);
  });

  test("summarise takes the label from the first user turn and counts them all", async () => {
    const dir = scratch();
    const path = join(dir, "s.jsonl");
    writeTranscript(path, 2600, "  read   my emails\nand slack  ");
    const { entries } = await readTranscript(path);
    const { label, turns } = summarise(entries);
    expect(label).toBe("read my emails and slack");
    // 2600 user messages -- assistant entries and the header are not turns.
    expect(turns).toBe(2600);
  });

  test("a stored offset makes a re-read seek instead of re-reading the file", async () => {
    const dir = scratch();
    const path = join(dir, "grow.jsonl");
    writeTranscript(path, 3, "first");
    const first = await readTranscript(path);
    expect(first.entries).toHaveLength(7); // header + 3 pairs

    appendFileSync(path, JSON.stringify({ type: "message", id: "z", message: { role: "user", content: "later" } }) + "\n");

    const rec = recordFileAccess();
    let second;
    try {
      second = await readTranscript(path, first.offset);
    } finally {
      rec.restore();
    }

    expect(second.entries).toHaveLength(1);
    expect(summarise(second.entries).label).toBe("later");
    expect(second.offset).toBe(Bun.file(path).size);
    // It seeked. Nothing slurped the prefix.
    expect(rec.calls).toContain("slice");
    for (const slurp of ["text", "bytes", "arrayBuffer"]) expect(rec.calls).not.toContain(slurp);
  });

  test("offsets are byte positions, so multibyte text does not drift", async () => {
    const dir = scratch();
    const path = join(dir, "utf8.jsonl");
    // Hebrew and an emoji: every one of these is >1 byte per character.
    writeFileSync(
      path,
      JSON.stringify({ type: "message", message: { role: "user", content: "שלום עולם 🌍" } }) + "\n",
    );
    const a = await readTranscript(path);
    expect(a.offset).toBe(Bun.file(path).size);

    appendFileSync(path, JSON.stringify({ type: "message", message: { role: "user", content: "next" } }) + "\n");
    const b = await readTranscript(path, a.offset);
    expect(b.entries).toHaveLength(1);
    expect(summarise(b.entries).label).toBe("next");
  });

  test("a half-written final line is left for the next read, not counted as read", async () => {
    const dir = scratch();
    const path = join(dir, "torn.jsonl");
    const good = JSON.stringify({ type: "message", message: { role: "user", content: "done" } });
    writeFileSync(path, good + "\n" + '{"type":"mess');

    const a = await readTranscript(path);
    expect(a.entries).toHaveLength(1);
    expect(a.torn).toBe(1);
    // Cursor sits BEFORE the torn line.
    expect(a.offset).toBe(Buffer.byteLength(good) + 1);

    // pi finishes the write.
    writeFileSync(path, good + "\n" + JSON.stringify({ type: "message", message: { role: "user", content: "rest" } }) + "\n");
    const b = await readTranscript(path, a.offset);
    expect(b.torn).toBe(0);
    expect(summarise(b.entries).label).toBe("rest");
  });

  test("a complete last line with no trailing newline is read once, not twice", async () => {
    const dir = scratch();
    const path = join(dir, "nonl.jsonl");
    const line = JSON.stringify({ type: "message", message: { role: "user", content: "solo" } });
    writeFileSync(path, line);

    const a = await readTranscript(path);
    expect(a.entries).toHaveLength(1);
    expect(a.offset).toBe(Buffer.byteLength(line));
    const b = await readTranscript(path, a.offset);
    expect(b.entries).toHaveLength(0);
  });

  test("string user content is handled as well as content blocks", () => {
    expect(
      summarise([{ type: "message", message: { role: "user", content: "plain string" } }]),
    ).toEqual({ label: "plain string", turns: 1 });
  });

  test("non-message entries never become a label", () => {
    const entries = [
      { type: "session", version: 3, id: "x", timestamp: "t", cwd: "/" },
      { type: "model_change", provider: "ollama", modelId: "glm" },
      { type: "message", message: { role: "assistant", content: [{ type: "text", text: "hi" }] } },
      { type: "message", message: { role: "toolResult", content: [{ type: "text", text: "out" }] } },
      null,
      "not an object",
      { type: "message", message: { role: "user", content: [{ type: "text", text: "the ask" }] } },
    ];
    expect(summarise(entries)).toEqual({ label: "the ask", turns: 1 });
  });
});
