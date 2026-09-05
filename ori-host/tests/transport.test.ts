import { afterEach, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  Conn,
  claimSocketPath,
  serve,
  socketPath,
  type OriServer,
  type TransportFs,
  type TransportHandlers,
  type WritableSocket,
} from "../src/transport";
import { log } from "../src/log";
import type { ClientCmd, HostEvent } from "../src/protocol";

// The transport logs every dropped frame and every displacement; that is the
// point of it, but it is noise in the runner. Capture instead.
const logged: string[] = [];
beforeAll(() => {
  log.setLevel("debug");
  log.setSink((line) => void logged.push(line));
});

const running: OriServer[] = [];
afterEach(() => {
  while (running.length) running.pop()!.stop();
});

function tmpSock(name = "ori.sock"): string {
  // Unix socket paths are capped at ~108 bytes, so a deep tmpdir would break
  // this before any assertion ran.
  return join(mkdtempSync(join(tmpdir(), "orit-")), name);
}

interface Harness {
  server: OriServer;
  path: string;
  cmds: Array<{ conn: Conn; cmd: ClientCmd }>;
  hellos: Array<{ conn: Conn; channel: string; displaced: boolean }>;
  gone: Array<{ conn: Conn; channel: string }>;
}

/** `extra` runs IN ADDITION to the recorders, never instead of them. */
async function harness(extra: Partial<TransportHandlers> = {}, at?: string): Promise<Harness> {
  const path = at ?? tmpSock();
  const cmds: Harness["cmds"] = [];
  const hellos: Harness["hellos"] = [];
  const gone: Harness["gone"] = [];
  const handlers: TransportHandlers = {
    onHello: (conn, channel, displaced) => {
      hellos.push({ conn, channel, displaced });
      extra.onHello?.(conn, channel, displaced);
    },
    onCommand: (conn, cmd) => {
      cmds.push({ conn, cmd });
      extra.onCommand?.(conn, cmd);
    },
    onGone: (conn, channel) => {
      gone.push({ conn, channel });
      extra.onGone?.(conn, channel);
    },
  };
  const server = await serve({ path, handlers });
  running.push(server);
  return { server, path, cmds, hellos, gone };
}

/** A client that keeps every NDJSON record the host sent it. */
async function client(path: string) {
  const lines: string[] = [];
  let rest = "";
  const dec = new TextDecoder();
  let closed = false;
  const sock = await Bun.connect({
    unix: path,
    socket: {
      data(_s, chunk) {
        rest += dec.decode(chunk, { stream: true });
        const parts = rest.split("\n");
        rest = parts.pop() ?? "";
        for (const p of parts) if (p !== "") lines.push(p);
      },
      close() {
        closed = true;
      },
      error() {
        closed = true;
      },
    },
  });
  return {
    lines,
    get closed() {
      return closed;
    },
    write: (s: string) => void sock.write(s),
    end: () => void sock.end(),
  };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Poll until `p` holds; far more robust than a fixed sleep on a socket test. */
async function until(p: () => boolean, ms = 5000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!p()) {
    if (Date.now() > deadline) throw new Error("timed out waiting for condition");
    await sleep(5);
  }
}

const HELLO = JSON.stringify({ t: "hello", channel: "panel", version: 1 }) + "\n";

/* ------------------------------------------------------------------ *
 * framing
 * ------------------------------------------------------------------ */

describe("NDJSON framing", () => {
  test("two records in one chunk yield two messages", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(
      HELLO +
        JSON.stringify({ t: "ask", text: "one", images: [] }) +
        "\n" +
        JSON.stringify({ t: "ask", text: "two", images: [] }) +
        "\n",
    );
    await until(() => h.cmds.length === 2);
    expect(h.cmds.map((x) => (x.cmd as { text: string }).text)).toEqual(["one", "two"]);
  });

  test("a record split across two chunks yields one message", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);

    const frame = JSON.stringify({ t: "ask", text: "split me", images: [] }) + "\n";
    c.write(frame.slice(0, 11));
    await sleep(30);
    expect(h.cmds).toHaveLength(0);
    c.write(frame.slice(11));
    await until(() => h.cmds.length === 1);
    expect((h.cmds[0]!.cmd as { text: string }).text).toBe("split me");
  });

  test("an invalid line is dropped, the connection survives and delivers the next record", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(HELLO + "{not json at all\n" + "[1,2,3]\n");
    await sleep(50);
    expect(h.cmds).toHaveLength(0);
    expect(c.closed).toBe(false);

    c.write(JSON.stringify({ t: "ask", text: "after the garbage", images: [] }) + "\n");
    await until(() => h.cmds.length === 1);
    expect((h.cmds[0]!.cmd as { text: string }).text).toBe("after the garbage");
    expect(c.closed).toBe(false);
  });

  test("feed() splits mid-UTF-8 chunks without corrupting the text", () => {
    // No socket: this is the pure half of the read path.
    const conn = new Conn(1, { write: () => 0, end: () => 0 });
    const bytes = new TextEncoder().encode(
      JSON.stringify({ t: "ask", text: "שלום עולם", images: [] }) + "\n",
    );
    // Cut one byte INTO a two-byte Hebrew code point -- the case a per-chunk
    // `decode()` turns into U+FFFD.
    const lead = bytes.findIndex((b) => b >= 0xc0);
    expect(lead).toBeGreaterThan(0);
    const cut = lead + 1;
    expect(conn.feed(bytes.subarray(0, cut))).toHaveLength(0);
    const out = conn.feed(bytes.subarray(cut));
    expect(out).toHaveLength(1);
    expect((out[0] as { text: string }).text).toBe("שלום עולם");
  });

  test("a frame before hello is dropped", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(JSON.stringify({ t: "ask", text: "too early", images: [] }) + "\n");
    await sleep(50);
    expect(h.cmds).toHaveLength(0);
    c.write(HELLO + JSON.stringify({ t: "ask", text: "now", images: [] }) + "\n");
    await until(() => h.cmds.length === 1);
    expect((h.cmds[0]!.cmd as { text: string }).text).toBe("now");
  });
});

/* ------------------------------------------------------------------ *
 * backpressure
 * ------------------------------------------------------------------ */

describe("backpressure", () => {
  test("payloads far larger than the socket buffer arrive intact and in order", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);
    const conn = h.hellos[0]!.conn;

    // 4 x 2 MB written in one tick. A snapshot is ~9 MB in practice, so this is
    // the real shape of the problem rather than a synthetic one.
    const payloads = [0, 1, 2, 3].map((i) => String.fromCharCode(97 + i).repeat(2 * 1024 * 1024));
    let maxPending = 0;
    for (const text of payloads) {
      conn.send({ t: "notice", text });
      maxPending = Math.max(maxPending, conn.pending);
    }

    await until(() => c.lines.length === 4, 20000);
    const got = c.lines.map((l) => JSON.parse(l) as HostEvent & { text: string });
    expect(got.map((g) => g.text.length)).toEqual(payloads.map((p) => p.length));
    expect(got.map((g) => g.text)).toEqual(payloads);
    // Not asserted (the kernel may swallow the lot), but recorded so a run that
    // never exercised the queue is visible rather than silently green.
    console.log(`[backpressure] peak queued bytes: ${maxPending}`);
  }, 30000);

  test("the write queue flushes in order against a socket that accepts 5 bytes at a time", () => {
    // Deterministic proof of the queue itself: no kernel, no timing.
    let out = "";
    let allow = 5;
    const dec = new TextDecoder();
    const fake: WritableSocket = {
      write(data) {
        const n = Math.min(allow, data.length);
        out += dec.decode(data.subarray(0, n));
        return n;
      },
      end: () => 0,
    };
    const conn = new Conn(2, fake);
    conn.send({ t: "notice", text: "first" });
    conn.send({ t: "notice", text: "second" });
    expect(conn.pending).toBeGreaterThan(0);

    // Drip: each drain accepts 5 more bytes, exactly as a real drain event does.
    for (let i = 0; i < 200 && conn.pending > 0; i++) conn.drain();
    expect(conn.pending).toBe(0);

    allow = Infinity;
    const lines = out.trim().split("\n").map((l) => JSON.parse(l) as { text: string });
    expect(lines.map((l) => l.text)).toEqual(["first", "second"]);
  });

  test("send() is a no-op once the connection is closed", () => {
    let writes = 0;
    const conn = new Conn(3, {
      write: (d) => {
        writes++;
        return d.length;
      },
      end: () => 0,
    });
    conn.close();
    conn.send({ t: "notice", text: "nobody is listening" });
    expect(writes).toBe(0);
    expect(conn.alive).toBe(false);
  });
});

/* ------------------------------------------------------------------ *
 * socket path ownership
 * ------------------------------------------------------------------ */

describe("socket path", () => {
  test("a stale socket file with nothing listening is unlinked and bound", async () => {
    const path = tmpSock();
    writeFileSync(path, ""); // stands in for the file a crashed host left behind
    expect(existsSync(path)).toBe(true);

    const h = await harness({}, path);
    const c = await client(path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);
    expect(h.hellos[0]!.channel).toBe("panel");
  });

  test("a REAL leftover socket inode (owner SIGKILLed) is unlinked and rebound", async () => {
    // Bun unlinks the socket on a graceful `server.stop()`, so the only honest
    // way to produce the file a crashed host leaves behind is to kill one.
    const path = tmpSock();
    const script = join(mkdtempSync(join(tmpdir(), "orit-child-")), "listen.ts");
    writeFileSync(
      script,
      `Bun.listen({ unix: ${JSON.stringify(path)}, socket: { data(){}, open(){}, close(){} } });\n` +
        `console.log("up");\nawait new Promise(() => {});\n`,
    );
    const child = Bun.spawn(["bun", "run", script], { stdout: "pipe", stderr: "ignore" });
    await until(() => existsSync(path), 10000);
    child.kill(9);
    await child.exited;
    expect(existsSync(path)).toBe(true); // a killed process unlinks nothing

    const h = await harness({}, path);
    const c = await client(path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);
  }, 20000);

  test("a live listener on the path makes startup fail rather than steal it", async () => {
    const first = await harness();
    let err: unknown;
    try {
      const second = await serve({
        path: first.path,
        handlers: { onHello: () => {}, onCommand: () => {}, onGone: () => {} },
      });
      running.push(second);
    } catch (e) {
      err = e;
    }
    expect(String(err)).toContain("already listening");

    // And the incumbent is untouched: it still serves.
    const c = await client(first.path);
    c.write(HELLO);
    await until(() => first.hellos.length === 1);
  });

  test("claimSocketPath probes before unlinking", async () => {
    const calls: string[] = [];
    const fs: TransportFs = {
      exists: () => (calls.push("exists"), true),
      unlink: () => void calls.push("unlink"),
      chmod: () => void calls.push("chmod"),
      probe: async () => (calls.push("probe"), false),
    };
    await claimSocketPath("/nowhere/ori.sock", fs);
    expect(calls).toEqual(["exists", "probe", "unlink"]);

    const alive: TransportFs = { ...fs, probe: async () => true };
    await expect(claimSocketPath("/nowhere/ori.sock", alive)).rejects.toThrow(
      /already listening/,
    );
  });

  test("socketPath refuses to fall back to /tmp", () => {
    expect(socketPath({ XDG_RUNTIME_DIR: "/run/user/1000" })).toBe("/run/user/1000/ori-agent.sock");
    expect(() => socketPath({})).toThrow(/XDG_RUNTIME_DIR/);
  });
});

/* ------------------------------------------------------------------ *
 * channel adoption
 * ------------------------------------------------------------------ */

describe("channel adoption", () => {
  test("a reconnect on a known channel adopts, and the displaced writer is mute", async () => {
    // A stand-in for the pool: one state object per channel, ever.
    const states = new Map<string, { created: number }>();
    let creations = 0;
    const h = await harness({
      onHello: (_conn, channel) => {
        if (!states.has(channel)) states.set(channel, { created: ++creations });
      },
    });

    const c1 = await client(h.path);
    c1.write(HELLO);
    await until(() => h.hellos.length === 1);
    const conn1 = h.hellos[0]!.conn;

    const c2 = await client(h.path);
    c2.write(HELLO);
    await until(() => h.hellos.length === 2);
    const conn2 = h.hellos[1]!.conn;

    expect(h.hellos[1]!.displaced).toBe(true);
    expect(states.size).toBe(1);
    expect(creations).toBe(1);
    expect(h.server.connFor("panel")).toBe(conn2);

    // The displaced connection can no longer write.
    expect(conn1.alive).toBe(false);
    conn1.send({ t: "notice", text: "from the ghost" });
    conn2.send({ t: "notice", text: "from the live one" });
    await until(() => c2.lines.length === 1);
    await sleep(50);
    expect(c1.lines).toHaveLength(0);
    expect(c2.lines.map((l) => (JSON.parse(l) as { text: string }).text)).toEqual([
      "from the live one",
    ]);
    await until(() => c1.closed);
  });

  test("a displaced connection's close does NOT fire onGone for the channel", async () => {
    const h = await harness();
    const c1 = await client(h.path);
    c1.write(HELLO);
    await until(() => h.hellos.length === 1);
    const c2 = await client(h.path);
    c2.write(HELLO);
    await until(() => h.hellos.length === 2);

    await until(() => c1.closed);
    await sleep(80);
    // The channel still belongs to conn2, so the pool must not start an orphan
    // grace for it -- this is the conn_token guarantee (ori-agent:485-494).
    expect(h.gone).toHaveLength(0);

    c2.end();
    await until(() => h.gone.length === 1);
    expect(h.gone[0]!.channel).toBe("panel");
    expect(h.server.connFor("panel")).toBeUndefined();
  });

  test("an empty channel gets an anonymous name and is never adopted", async () => {
    const h = await harness();
    const anon = JSON.stringify({ t: "hello", channel: "", version: 1 }) + "\n";
    const c1 = await client(h.path);
    c1.write(anon);
    await until(() => h.hellos.length === 1);
    const c2 = await client(h.path);
    c2.write(anon);
    await until(() => h.hellos.length === 2);

    expect(h.hellos[0]!.channel).not.toBe(h.hellos[1]!.channel);
    expect(h.hellos[0]!.channel).toStartWith("anon-");
    expect(h.hellos[1]!.displaced).toBe(false);
    expect(c1.closed).toBe(false);
  });

  test("a second hello on one connection moves the channel key", async () => {
    const h = await harness();
    const c = await client(h.path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);
    c.write(JSON.stringify({ t: "hello", channel: "other", version: 1 }) + "\n");
    await until(() => h.hellos.length === 2);

    expect(h.server.connFor("panel")).toBeUndefined();
    expect(h.server.connFor("other")).toBe(h.hellos[0]!.conn);
    expect(h.hellos[1]!.displaced).toBe(false);
  });
});

/* ------------------------------------------------------------------ *
 * handler containment
 * ------------------------------------------------------------------ */

/** Records logged since the call, so a shared sink cannot leak across tests. */
function loggedSince(n: number): Array<{ msg: string }> {
  return logged.slice(n).map((l) => JSON.parse(l) as { msg: string });
}

describe("handler containment", () => {
  test("a throwing onHello does not swallow the rest of the chunk", async () => {
    // The reconnect-and-resend burst: hello and both asks land in ONE chunk, so
    // an unguarded throw out of the pool would drop both user messages with
    // nothing on stderr -- Bun swallows exceptions from the data callback.
    const h = await harness({
      onHello: () => {
        throw new Error("pool exploded");
      },
    });
    const at = logged.length;
    const c = await client(h.path);
    c.write(
      HELLO +
        JSON.stringify({ t: "ask", text: "one", images: [] }) +
        "\n" +
        JSON.stringify({ t: "ask", text: "two", images: [] }) +
        "\n",
    );
    await until(() => h.cmds.length === 2);
    expect(h.cmds.map((x) => (x.cmd as { text: string }).text)).toEqual(["one", "two"]);
    expect(c.closed).toBe(false);
    expect(loggedSince(at).map((r) => r.msg)).toContain("hello handler threw");
  });

  test("a throwing onGone is logged rather than escaping the close handler", async () => {
    const h = await harness({
      onGone: () => {
        throw new Error("grace start exploded");
      },
    });
    const c = await client(h.path);
    c.write(HELLO);
    await until(() => h.hellos.length === 1);

    const at = logged.length;
    c.end();
    await until(() => h.gone.length === 1);
    await until(() => loggedSince(at).some((r) => r.msg === "gone handler threw"));
    // The routing map is cleaned up regardless of what the pool did.
    expect(h.server.connFor("panel")).toBeUndefined();
  });
});
