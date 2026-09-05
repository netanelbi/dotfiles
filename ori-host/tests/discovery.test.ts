/**
 * Session discovery: finding conversations the index has never seen.
 *
 * The bug this suite pins down was observed live -- `resume 01a05285` answered
 * `no such session` for a session sitting on disk with 1020 entries, because the
 * index only ever knew sessions the host itself had created. Everything below is
 * about finding those files WITHOUT paying to read them: the user has ~40
 * sessions and the largest is 9.9 MB.
 *
 * Nothing here touches `~/.pi` or the real index. Every path is a tmpdir.
 */

import { afterEach, describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Host } from "../src/main";
import type { CatalogPaths } from "../src/catalog";
import type { ClientCmd, HostEvent } from "../src/protocol";
import {
  encodeCwd,
  HEAD_BYTES,
  headLabel,
  piSessionDir,
  readLegacyIndex,
  scanSessions,
  Store,
} from "../src/store";
import { defaultUsageIo, type UsageIo } from "../src/usage";

const tmps: string[] = [];
function scratch(): string {
  const d = mkdtempSync(join(tmpdir(), "ori-discovery-"));
  tmps.push(d);
  return d;
}
afterEach(() => {
  while (tmps.length) rmSync(tmps.pop()!, { recursive: true, force: true });
});

/* ------------------------------------------------------------------ *
 * fixtures shaped exactly like pi's
 * ------------------------------------------------------------------ */

const header = (id: string, cwd: string): string =>
  JSON.stringify({ type: "session", version: 3, id, timestamp: "2026-08-30T11:54:52.131Z", cwd });

const userLine = (text: string): string =>
  JSON.stringify({
    type: "message",
    id: "u",
    parentId: null,
    timestamp: "2026-08-30T11:54:52.239Z",
    message: { role: "user", content: [{ type: "text", text }] },
  });

const assistantLine = (text: string): string =>
  JSON.stringify({
    type: "message",
    id: "a",
    parentId: "u",
    timestamp: "2026-08-30T11:54:53.000Z",
    message: { role: "assistant", content: [{ type: "text", text }] },
  });

/**
 * A session file with pi's real header run-up: `session`, `model_change`,
 * `thinking_level_change`, THEN the first user message -- which is what puts the
 * label ~640 bytes into the 9.9 MB file on this machine.
 */
function writeSession(dir: string, name: string, ask: string, extraLines: string[] = []): string {
  const path = join(dir, name);
  const id = name.slice(name.lastIndexOf("_") + 1).replace(/\.jsonl$/, "");
  const lines = [
    header(id, "/home/x/.dotfiles"),
    JSON.stringify({ type: "model_change", id: "m", provider: "ollama", modelId: "glm-5.3-flash" }),
    JSON.stringify({ type: "thinking_level_change", id: "t", thinkingLevel: "medium" }),
    userLine(ask),
    assistantLine("sure"),
    ...extraLines,
  ];
  writeFileSync(path, lines.join("\n") + "\n");
  return path;
}

/** pi's own directory layout, so `piSessionDir` is exercised rather than
 *  hardcoded. */
function piLayout(home: string, workdir: string): string {
  const dir = piSessionDir({ workdir, home });
  mkdirSync(dir, { recursive: true });
  return dir;
}

/* ------------------------------------------------------------------ *
 * 1. the scan itself
 * ------------------------------------------------------------------ */

describe("encodeCwd", () => {
  test("matches pi's own encoding", () => {
    // Verified against the real directory:
    //   /home/netanel/.dotfiles -> --home-netanel-.dotfiles--
    expect(encodeCwd("/home/netanel/.dotfiles")).toBe("--home-netanel-.dotfiles--");
    expect(encodeCwd("/home/netanel")).toBe("--home-netanel--");
    expect(encodeCwd("/home/netanel/.claude/jobs/145911fd/tmp")).toBe(
      "--home-netanel-.claude-jobs-145911fd-tmp--",
    );
  });

  test("piSessionDir derives the path, and PI_CODING_AGENT_SESSION_DIR wins", () => {
    expect(piSessionDir({ workdir: "/home/n/.dotfiles", home: "/home/n" })).toBe(
      "/home/n/.pi/agent/sessions/--home-n-.dotfiles--",
    );
    // The env var names the session directory ITSELF, not its parent.
    expect(piSessionDir({ workdir: "/home/n/.dotfiles", home: "/home/n", env: "~/elsewhere" })).toBe(
      "/home/n/elsewhere",
    );
  });
});

describe("scanSessions", () => {
  test("finds sessions laid out like pi's, with id, label and mtime", async () => {
    const home = scratch();
    const dir = piLayout(home, "/home/x/.dotfiles");

    // A real filename: <ISO-ish timestamp>_<uuid>.jsonl.
    const a = writeSession(
      dir,
      "2026-08-30T11-54-52-131Z_01a05285-bf63-7fcd-a3fc-2edd7fcf406c.jsonl",
      "  read my emails\nans slack   messages please ",
    );
    const b = writeSession(dir, "2026-05-04T06-21-26-424Z_019df1a6-1417-74ae-9b2a-2cef48893e64.jsonl", "ping");
    // Not a session file, and must not become a row.
    writeFileSync(join(dir, "notes.txt"), "ignore me");

    utimesSync(a, new Date(2_000_000), new Date(2_000_000));
    utimesSync(b, new Date(1_000_000), new Date(1_000_000));

    const { found, stamps, read } = await scanSessions(dir);
    expect(read).toBe(2);
    expect(stamps.size).toBe(2);

    const byId = new Map(found.map((f) => [f.id, f]));
    expect([...byId.keys()].sort()).toEqual([
      "019df1a6-1417-74ae-9b2a-2cef48893e64",
      "01a05285-bf63-7fcd-a3fc-2edd7fcf406c",
    ]);

    // The id is the uuid AFTER the timestamp prefix, not the whole basename.
    const first = byId.get("01a05285-bf63-7fcd-a3fc-2edd7fcf406c")!;
    expect(first.file).toBe(a);
    // Whitespace collapsed, exactly as the old sessionLabel() did.
    expect(first.label).toBe("read my emails ans slack messages please");
    expect(first.at).toBe(2_000_000);
    // 0, not a guess: counting turns means reading the whole file.
    expect(first.turns).toBe(0);

    expect(byId.get("019df1a6-1417-74ae-9b2a-2cef48893e64")!.at).toBe(1_000_000);
  });

  test("a missing session directory is empty, not an error", async () => {
    const { found, stamps, read } = await scanSessions(join(scratch(), "never-ran"));
    expect(found).toEqual([]);
    expect(stamps.size).toBe(0);
    expect(read).toBe(0);
  });

  test("a session with no readable user message still gets a row", async () => {
    const dir = scratch();
    // Header only: opened and abandoned. It must still be pickable -- a session
    // that exists but cannot be seen is the whole bug.
    writeFileSync(
      join(dir, "2026-08-30T11-54-52-131Z_deadbeef.jsonl"),
      header("deadbeef", "/home/x") + "\n",
    );
    const { found } = await scanSessions(dir);
    expect(found).toHaveLength(1);
    expect(found[0]!.id).toBe("deadbeef");
    expect(found[0]!.label).toBe("2026-08-30T11-54-52-131Z");
  });

  test("one unopenable file costs one row, not the whole directory", async () => {
    const dir = scratch();
    writeSession(dir, "2026-08-30T11-54-52-131Z_aaaa.jsonl", "first");
    writeSession(dir, "2026-08-30T11-54-53-131Z_bbbb.jsonl", "second");
    writeSession(dir, "2026-08-30T11-54-54-131Z_cccc.jsonl", "third");
    // Measured before the fix: `headLabel` threw EACCES straight out of the
    // loop, so the scan returned nothing at all and the picker stayed empty.
    const bad = writeSession(dir, "2026-08-30T11-54-55-131Z_dddd.jsonl", "locked");
    chmodSync(bad, 0o000);

    const { found, stamps } = await scanSessions(dir);
    expect(found.map((f) => f.id).sort()).toEqual(["aaaa", "bbbb", "cccc"]);
    // No stamp for the file that could not be read -- see the retry test below.
    expect([...stamps.keys()].some((p) => p === bad)).toBe(false);
  });

  test("a file that becomes readable is picked up by the next scan", async () => {
    const dir = scratch();
    const bad = writeSession(dir, "2026-08-30T11-54-55-131Z_dddd.jsonl", "locked");
    chmodSync(bad, 0o000);

    const first = await scanSessions(dir);
    expect(first.found).toEqual([]);

    // A chmod changes neither mtime nor size, so if the failed read had left a
    // stamp behind the change check would skip this file forever.
    chmodSync(bad, 0o644);
    const second = await scanSessions(dir, first.stamps);
    expect(second.found.map((f) => f.id)).toEqual(["dddd"]);
    expect(second.found[0]!.label).toBe("locked");
  });

  test("a file deleted between the stat and the read does not abort the scan", async () => {
    const dir = scratch();
    writeSession(dir, "2026-08-30T11-54-52-131Z_aaaa.jsonl", "survivor");
    const doomed = writeSession(dir, "2026-08-30T11-54-53-131Z_bbbb.jsonl", "about to vanish");

    // Delete it once its stat has been taken -- exactly the race the stat's own
    // guard already handles, one step later in the same loop body.
    const real = Bun.file;
    let armed = true;
    (Bun as { file: typeof Bun.file }).file = ((...args: Parameters<typeof Bun.file>) => {
      // Stringified because the overload `Parameters` resolves to takes a file
      // descriptor, so a bare `=== doomed` is a number-vs-string comparison.
      if (armed && String(args[0]) === doomed) {
        armed = false;
        rmSync(doomed);
      }
      return real(...args);
    }) as typeof Bun.file;

    try {
      const { found } = await scanSessions(dir);
      expect(found.map((f) => f.id)).toEqual(["aaaa"]);
    } finally {
      (Bun as { file: typeof Bun.file }).file = real;
    }
  });
});

/* ------------------------------------------------------------------ *
 * 2. the label read is BOUNDED
 * ------------------------------------------------------------------ */

/**
 * Replace `Bun.file` with a recorder that counts the bytes that actually reach
 * this process, so "it only read the head" is a measurement rather than a claim.
 *
 * It wraps the BLOB returned by `.slice()` too, because that is where the read
 * happens: `slice()` alone is just an offset and a length.
 */
function recordBytes(): {
  bytes: number;
  slices: Array<[number, number | undefined]>;
  slurps: string[];
  restore: () => void;
} {
  const state = {
    bytes: 0,
    slices: [] as Array<[number, number | undefined]>,
    slurps: [] as string[],
    restore: () => {},
  };
  const real = Bun.file;

  const countingBlob = (blob: Blob): Blob =>
    new Proxy(blob, {
      get(target, prop, recv) {
        if (prop === "text") {
          return async (): Promise<string> => {
            const s = await target.text();
            state.bytes += Buffer.byteLength(s, "utf8");
            return s;
          };
        }
        const v = Reflect.get(target, prop, recv) as unknown;
        return typeof v === "function" ? (v as () => unknown).bind(target) : v;
      },
    });

  const patched = ((...args: Parameters<typeof Bun.file>) => {
    const f = real(...args);
    return new Proxy(f, {
      get(target, prop, recv) {
        if (prop === "slice") {
          return (start?: number, end?: number): Blob => {
            state.slices.push([start ?? 0, end]);
            return countingBlob(target.slice(start, end));
          };
        }
        // Every accessor that would pull the WHOLE file into memory -- what the
        // old code did, and what this must never do.
        if (prop === "text" || prop === "bytes" || prop === "arrayBuffer" || prop === "json") {
          state.slurps.push(String(prop));
        }
        const v = Reflect.get(target, prop, recv) as unknown;
        return typeof v === "function" ? (v as () => unknown).bind(target) : v;
      },
    });
  }) as typeof Bun.file;

  (Bun as { file: typeof Bun.file }).file = patched;
  state.restore = () => {
    (Bun as { file: typeof Bun.file }).file = real;
  };
  return state;
}

describe("the label read is bounded", () => {
  test("an 8 MB session costs one head-sized read, not the file", async () => {
    const dir = scratch();
    const name = "2026-08-30T11-54-52-131Z_01a05285-bf63-7fcd-a3fc-2edd7fcf406c.jsonl";
    // Padding lines AFTER the opening question, exactly like a real transcript:
    // the label is near the top, the bulk is tool output nobody needs to name a
    // session.
    const filler = assistantLine("x".repeat(64 * 1024));
    const pad: string[] = [];
    for (let i = 0; i < 130; i++) pad.push(filler);
    const path = writeSession(dir, name, "the opening question", pad);

    const size = Bun.file(path).size;
    expect(size).toBeGreaterThan(8 * 1024 * 1024);

    const rec = recordBytes();
    const started = Bun.nanoseconds();
    let found;
    try {
      found = await scanSessions(dir);
    } finally {
      rec.restore();
    }
    const ms = (Bun.nanoseconds() - started) / 1e6;

    expect(found.found).toHaveLength(1);
    expect(found.found[0]!.label).toBe("the opening question");

    // THE assertion: bytes that reached this process.
    expect(rec.bytes).toBeLessThanOrEqual(HEAD_BYTES);
    expect(rec.bytes).toBeLessThan(size / 100);
    // And it got them by seeking, not by slurping and slicing a string.
    expect(rec.slices).toEqual([[0, HEAD_BYTES]]);
    expect(rec.slurps).toEqual([]);

    // Secondary, and only a corroboration: decoding 8 MB of UTF-8 and splitting
    // it on "\n" cannot be done in 100 ms, so this bound cannot be met by a
    // whole-file read even entirely from page cache. The byte count above is the
    // real proof; this catches an instrumentation that lies.
    expect(ms).toBeLessThan(100);
  }, 30_000);

  test("headLabel reads past a torn window edge rather than choking on it", async () => {
    const dir = scratch();
    const path = join(dir, "cut.jsonl");
    // First user message is longer than the window, so its line is cut in half
    // and cannot parse; the next one fits.
    writeFileSync(
      path,
      [header("x", "/h"), userLine("A".repeat(4096)), userLine("second question")].join("\n") + "\n",
    );
    expect(await headLabel(path, 512)).toBe("");
    expect(await headLabel(path, 8192)).toBe("A".repeat(90) + "…");
  });
});

/* ------------------------------------------------------------------ *
 * 3. migrating the old JSON index
 * ------------------------------------------------------------------ */

describe("legacy index migration", () => {
  test("readLegacyIndex parses the panel's file and maps count -> turns", async () => {
    const dir = scratch();
    const path = join(dir, "ori-sessions.json");
    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        sessions: [
          { id: "01a05285", file: "/s/a.jsonl", label: "read my emails", at: 1788590809577, count: 972 },
          { id: "01a053ff", file: "/s/b.jsonl", label: "ping", at: 1788590806576, count: 6 },
          { nonsense: true },
        ],
      }),
    );
    const rows = (await readLegacyIndex(path))!;
    expect(rows).toHaveLength(2);
    expect(rows[0]).toEqual({
      id: "01a05285",
      file: "/s/a.jsonl",
      label: "read my emails",
      at: 1788590809577,
      turns: 972,
    });
  });

  test("an absent file is null (so it is not recorded as migrated)", async () => {
    expect(await readLegacyIndex(join(scratch(), "nope.json"))).toBeNull();
  });

  test("seeding migrates, and a later scan does NOT clobber the turn counts", async () => {
    const home = scratch();
    const dir = piLayout(home, "/home/x/.dotfiles");
    const name = "2026-08-30T11-54-52-131Z_01a05285-bf63-7fcd-a3fc-2edd7fcf406c.jsonl";
    const file = writeSession(dir, name, "read my emails ans slack messages please");
    // Newer than the `at` the old index recorded, which is the realistic case:
    // the panel stopped writing that file before pi stopped writing this one.
    const mtime = 1_788_600_000_000;
    utimesSync(file, new Date(mtime), new Date(mtime));

    const legacy = join(home, "ori-sessions.json");
    writeFileSync(
      legacy,
      JSON.stringify({
        version: 1,
        sessions: [
          {
            id: "01a05285-bf63-7fcd-a3fc-2edd7fcf406c",
            file,
            label: "read my emails ans slack messages please",
            at: 1788590809577,
            count: 972,
          },
        ],
      }),
    );

    const store = new Store();
    store.seed((await readLegacyIndex(legacy))!);
    expect(store.byId("01a05285")).toMatchObject({ turns: 972, at: 1788590809577 });

    // The scan reports turns = 0 for the very same session.
    const { found } = await scanSessions(dir);
    expect(found[0]!.turns).toBe(0);
    store.seed(found);

    const row = store.byId("01a05285-bf63-7fcd-a3fc-2edd7fcf406c")!;
    expect(row.turns).toBe(972); // NOT 0
    expect(row.label).toBe("read my emails ans slack messages please");
    // The file's mtime is newer than what the old index recorded, so recency
    // moves forward rather than backward.
    expect(row.at).toBe(mtime);
    store.close();
  });

  test("the reverse order is equally safe: scan first, migrate second", async () => {
    const home = scratch();
    const dir = piLayout(home, "/home/x/.dotfiles");
    const name = "2026-08-30T11-54-52-131Z_01a05285.jsonl";
    const file = writeSession(dir, name, "read my emails");

    const store = new Store();
    store.seed((await scanSessions(dir)).found);
    expect(store.byId("01a05285")!.turns).toBe(0);

    store.seed([{ id: "01a05285", file, label: "read my emails", at: 1, turns: 972 }]);
    expect(store.byId("01a05285")!.turns).toBe(972);
    store.close();
  });

  test("seed never overwrites a row a settled turn wrote", () => {
    const store = new Store();
    store.upsert({ id: "s", file: "/s/live.jsonl", label: "the real label", at: 500, turns: 12 });
    store.setOffset("s", 4096);
    store.seed([{ id: "s", file: "/s/live.jsonl", label: "a scanned guess", at: 400, turns: 0 }]);

    const row = store.byId("s")!;
    expect(row.label).toBe("the real label");
    expect(row.turns).toBe(12);
    expect(row.at).toBe(500);
    // And the transcript cursor is untouched, so a re-read still seeks.
    expect(row.readOffset).toBe(4096);
    store.close();
  });

  test("meta records the migration so the file is read once", () => {
    const store = new Store();
    expect(store.meta("legacyIndexMigrated")).toBeNull();
    store.setMeta("legacyIndexMigrated", "1788590809577");
    expect(store.meta("legacyIndexMigrated")).toBe("1788590809577");
    store.close();
  });
});

/* ------------------------------------------------------------------ *
 * 4. a re-scan is cheap
 * ------------------------------------------------------------------ */

describe("re-scan", () => {
  test("skips files whose mtime and size are unchanged", async () => {
    const dir = scratch();
    const a = writeSession(dir, "2026-08-30T11-54-52-131Z_aaa.jsonl", "first");
    writeSession(dir, "2026-08-30T12-00-00-000Z_bbb.jsonl", "second");

    const first = await scanSessions(dir);
    expect(first.read).toBe(2);
    expect(first.found).toHaveLength(2);

    // Nothing moved: two stats, zero opens, zero rows.
    const rec = recordBytes();
    let second;
    try {
      second = await scanSessions(dir, first.stamps);
    } finally {
      rec.restore();
    }
    expect(second.read).toBe(0);
    expect(second.found).toEqual([]);
    expect(rec.bytes).toBe(0);
    expect(rec.slices).toEqual([]);
    // The stamps still cover every file, so the next scan is cheap too.
    expect(second.stamps.size).toBe(2);

    // One file grows: only that one is re-read.
    writeFileSync(a, [header("aaa", "/h"), userLine("first"), assistantLine("more")].join("\n") + "\n");
    const third = await scanSessions(dir, second.stamps);
    expect(third.read).toBe(1);
    expect(third.found.map((f) => f.id)).toEqual(["aaa"]);

    // A brand new session is found on the next scan without a watcher.
    writeSession(dir, "2026-08-31T09-00-00-000Z_ccc.jsonl", "third");
    const fourth = await scanSessions(dir, third.stamps);
    expect(fourth.found.map((f) => f.id)).toEqual(["ccc"]);
    expect(fourth.stamps.size).toBe(3);
  });

  test("a same-size rewrite still counts as changed, because mtime moved", async () => {
    const dir = scratch();
    const a = writeSession(dir, "2026-08-30T11-54-52-131Z_aaa.jsonl", "aaaaa");
    utimesSync(a, new Date(1_788_600_000_000), new Date(1_788_600_000_000));
    const first = await scanSessions(dir);

    // Byte-for-byte the same length, so `size` alone cannot see this.
    writeSession(dir, "2026-08-30T11-54-52-131Z_aaa.jsonl", "bbbbb");
    utimesSync(a, new Date(1_788_600_001_000), new Date(1_788_600_001_000));
    expect(Bun.file(a).size).toBe(first.stamps.get(a)!.size);

    const second = await scanSessions(dir, first.stamps);
    expect(second.found).toHaveLength(1);
    expect(second.found[0]!.label).toBe("bbbbb");
  });
});

/* ------------------------------------------------------------------ *
 * 5. the restore race, against the real host
 * ------------------------------------------------------------------ */

/** A pi that never answers. The question still has to reach the turn list, and
 *  the history still has to be there when it does. */
const MUTE_PI = "#!/bin/sh\nwhile IFS= read -r line; do :; done\n";

/** No key, so `OllamaUsage` never reaches the network from a test. */
const offlineUsage: UsageIo = { ...defaultUsageIo, envKey: () => "", fileKey: async () => "" };

class TestClient {
  readonly events: HostEvent[] = [];
  #socket: Awaited<ReturnType<typeof Bun.connect>> | null = null;
  #rest = "";
  #woke: Array<() => void> = [];

  static async connect(path: string): Promise<TestClient> {
    const client = new TestClient();
    client.#socket = await Bun.connect({
      unix: path,
      socket: {
        data(_s, chunk) {
          client.#feed(chunk);
        },
        error() {},
        close() {},
      },
    });
    return client;
  }

  #feed(chunk: Uint8Array): void {
    this.#rest += new TextDecoder().decode(chunk);
    const parts = this.#rest.split("\n");
    this.#rest = parts.pop() ?? "";
    for (const line of parts) {
      if (line === "") continue;
      this.events.push(JSON.parse(line) as HostEvent);
    }
    for (const wake of this.#woke.splice(0)) wake();
  }

  send(cmd: ClientCmd): void {
    this.#socket?.write(JSON.stringify(cmd) + "\n");
  }

  async waitFor(pred: (ev: HostEvent) => boolean, timeoutMs = 15_000): Promise<HostEvent> {
    const deadline = Date.now() + timeoutMs;
    let seen = 0;
    for (;;) {
      for (; seen < this.events.length; seen++) {
        const ev = this.events[seen]!;
        if (pred(ev)) return ev;
      }
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("timed out waiting for an event");
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(left, 25));
        this.#woke.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  close(): void {
    this.#socket?.end();
    this.#socket = null;
  }
}

describe("host discovery and restore", () => {
  test("a session only on disk is discoverable, and a question mid-restore keeps its history", async () => {
    const home = scratch();
    const dir = piLayout(home, home);
    const cfg = join(home, "cfg");
    mkdirSync(cfg, { recursive: true });
    const fakePi = join(home, "mute-pi");
    writeFileSync(fakePi, MUTE_PI);
    chmodSync(fakePi, 0o755);

    // A transcript big enough that reading it is unambiguously still in flight
    // when the next command off the socket is handled -- ~40k lines, ~4 MB.
    const sessionId = "01a05285-bf63-7fcd-a3fc-2edd7fcf406c";
    const extra: string[] = [];
    for (let i = 1; i < 20_000; i++) {
      extra.push(userLine(`follow up ${i}`), assistantLine(`answer ${i} ${"y".repeat(100)}`));
    }
    const file = writeSession(
      dir,
      `2026-08-30T11-54-52-131Z_${sessionId}.jsonl`,
      "the opening question",
      extra,
    );
    expect(Bun.file(file).size).toBeGreaterThan(3 * 1024 * 1024);

    const paths: CatalogPaths = {
      settings: join(cfg, "settings.json"),
      models: join(cfg, "models.json"),
      registry: join(cfg, "registry.json"),
      choice: join(cfg, "ori-model.json"),
      cache: join(cfg, "ori-catalog.json"),
    };
    const host = new Host({
      socket: join(home, "ori.sock"),
      dbPath: join(home, "sessions.db"),
      home,
      runtimeDir: home,
      sessionDir: dir,
      legacyIndex: join(home, "no-such-legacy.json"),
      catalogPaths: paths,
      spawn: { binary: fakePi, workdir: home, promptFiles: [], extensions: [] },
      usageIo: offlineUsage,
    });

    try {
      await host.start();
      // The scan `start()` kicked off in the background; joined here so the
      // assertion below is about discovery and not about timing.
      await host.discover();

      // THE ORIGINAL SYMPTOM: `resume <id>` used to answer "no such session"
      // for a file that was right there.
      expect(host.store.byId("01a05285")?.file).toBe(file);
      expect(host.store.byId(sessionId)?.label).toBe("the opening question");

      const client = await TestClient.connect(host.socketPath);
      client.send({ t: "hello", channel: "discovery-test", version: 1 });
      await client.waitFor((e) => e.t === "hello");

      // Resume and ask BACK TO BACK, so the question is handled while the
      // transcript read is still running. Without the fix the read loses the
      // race, refuses to install, and never tries again.
      client.send({ t: "resume", id: "r", sessionId });
      client.send({ t: "ask", id: "q", text: "mid-read", images: [] });

      await client.waitFor(
        (e) => e.t === "turn_add" && e.turn.role === "user" && e.turn.text === "mid-read",
      );

      // A fresh snapshot is the authoritative answer to "what does this
      // conversation hold".
      const mark = client.events.length;
      client.send({ t: "resync", id: "s" });
      const snap = await client.waitFor(
        (e) => e.t === "snapshot" && client.events.indexOf(e) >= mark,
      );
      if (snap.t !== "snapshot") throw new Error("not a snapshot");

      // The history survived, in order, with the new question appended to it --
      // not replacing it, and not lost to it.
      // 20_000 exchanges off the file, plus the question and the empty
      // assistant row `ask()` opens for it to stream into.
      expect(snap.turns).toHaveLength(40_002);
      expect(snap.turns[0]!.role).toBe("user");
      expect(snap.turns[0]!.text).toBe("the opening question");
      expect(snap.turns[39_999]!.text).toBe(`answer 19999 ${"y".repeat(100)}`);
      // The question is AFTER all of it -- appended to the history, not
      // replacing it and not lost to it.
      expect(snap.turns[40_000]).toMatchObject({ role: "user", text: "mid-read" });
      expect(snap.turns[40_001]).toMatchObject({ role: "assistant", pending: true });
      // Exactly one row carries the question: the restore did not run twice.
      expect(snap.turns.filter((t) => t.text === "mid-read")).toHaveLength(1);

      client.close();
    } finally {
      await host.stop();
    }
  }, 60_000);
});

/* ------------------------------------------------------------------ *
 * 6. attach_path, against the real host
 * ------------------------------------------------------------------ */

describe("attach_path", () => {
  test("stages a named file, echoes the id, and the marker resolves into the ask", async () => {
    const home = scratch();
    const dir = piLayout(home, home);
    const cfg = join(home, "cfg");
    mkdirSync(cfg, { recursive: true });
    const fakePi = join(home, "mute-pi");
    writeFileSync(fakePi, MUTE_PI);
    chmodSync(fakePi, 0o755);

    // Magic bytes are what sniffMime reads -- the extension is never consulted,
    // deliberately (images.ts).
    const png = join(home, "shot.png");
    writeFileSync(png, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]));
    const notImage = join(home, "notes.png");
    writeFileSync(notImage, "this is text wearing a .png suffix\n");

    const host = new Host({
      socket: join(home, "ori.sock"),
      dbPath: join(home, "sessions.db"),
      home,
      runtimeDir: home,
      sessionDir: dir,
      legacyIndex: join(home, "no-such-legacy.json"),
      catalogPaths: {
        settings: join(cfg, "settings.json"),
        models: join(cfg, "models.json"),
        registry: join(cfg, "registry.json"),
        choice: join(cfg, "ori-model.json"),
        cache: join(cfg, "ori-catalog.json"),
      },
      spawn: { binary: fakePi, workdir: home, promptFiles: [], extensions: [] },
      usageIo: offlineUsage,
    });

    try {
      await host.start();
      const client = await TestClient.connect(host.socketPath);
      client.send({ t: "hello", channel: "attach-test", version: 1 });
      await client.waitFor((e) => e.t === "hello");

      // THE ORIGINAL SYMPTOM: attach_path was in the ClientCmd union with no
      // arm in #onCommand, so the host answered NOTHING -- not `attached`, not
      // `attach_failed`, not even the `ack` the id asked for -- and `ori image`
      // sat until its own 10s deadline and dropped the question.
      client.send({ t: "attach_path", id: "p1", path: png });
      const ok = await client.waitFor((e) => e.t === "attached");
      if (ok.t !== "attached") throw new Error("not an attached");
      expect(ok.id).toBe("p1");
      expect(ok.path).toBe(png);
      expect(ok.n).toBe(1);
      await client.waitFor((e) => e.t === "ack" && e.id === "p1" && e.ok);

      // Verified at STAGING time, not at send time: a marker handed out for a
      // file that is not an image would fail long after the caller was told the
      // picture was staged.
      client.send({ t: "attach_path", id: "p2", path: notImage });
      const bad = await client.waitFor((e) => e.t === "attach_failed");
      if (bad.t !== "attach_failed") throw new Error("not an attach_failed");
      expect(bad.id).toBe("p2");
      expect(bad.why).toContain("not an image");
      const nack = await client.waitFor((e) => e.t === "ack" && e.id === "p2");
      if (nack.t !== "ack") throw new Error("not an ack");
      expect(nack.ok).toBe(false);

      client.send({ t: "attach_path", id: "p3", path: join(home, "no-such.png") });
      const missing = await client.waitFor((e) => e.t === "attach_failed" && e.id === "p3");
      if (missing.t !== "attach_failed") throw new Error("not an attach_failed");
      expect(missing.why).toContain("cannot read image");

      // The marker the host handed out resolves to the picture on the question
      // -- which is the whole point of the round trip.
      client.send({ t: "ask", id: "q", text: "what is this?", images: [ok.n] });
      const asked = await client.waitFor((e) => e.t === "turn_add" && e.turn.role === "user");
      if (asked.t !== "turn_add") throw new Error("not a turn_add");
      expect(asked.turn.images).toEqual([{ path: png, mime: "image/png", bytes: 12 }]);

      client.close();
    } finally {
      await host.stop();
    }
  }, 30_000);
});
