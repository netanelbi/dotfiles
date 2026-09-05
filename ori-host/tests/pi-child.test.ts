import { describe, expect, test } from "bun:test";
import type { PiSpawnConfig } from "../src/pi/argv";
import {
  PiChild,
  type ChildProcessLike,
  type PiChildDeps,
  type PiExit,
  type SpawnOptions,
} from "../src/pi/child";
import type { PiFrame } from "../src/pi/pi-types";

const HOME = "/home/tester";
const enc = new TextEncoder();

/* ------------------------------------------------------------------ *
 * A fake child. No process, no socket, no clock.
 * ------------------------------------------------------------------ */

/** A hand-driven async byte stream: push() feeds one chunk, close() ends it. */
class Feed implements AsyncIterable<Uint8Array> {
  private queue: Uint8Array[] = [];
  private waiter: (() => void) | null = null;
  private done = false;

  push(s: string): void {
    this.queue.push(enc.encode(s));
    this.wake();
  }
  /** Raw bytes, for splitting a multi-byte character across chunks. */
  pushBytes(b: Uint8Array): void {
    this.queue.push(b);
    this.wake();
  }
  close(): void {
    this.done = true;
    this.wake();
  }
  private wake(): void {
    const w = this.waiter;
    this.waiter = null;
    w?.();
  }
  async *[Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    for (;;) {
      const next = this.queue.shift();
      if (next !== undefined) {
        yield next;
        continue;
      }
      if (this.done) return;
      await new Promise<void>((r) => {
        this.waiter = r;
      });
    }
  }
}

class FakeProc implements ChildProcessLike {
  readonly pid = 4242;
  readonly out = new Feed();
  readonly err = new Feed();
  readonly writes: string[] = [];
  flushes = 0;
  readonly signals: (number | NodeJS.Signals)[] = [];
  exitCode: number | null = null;
  signalCode: string | null = null;

  private resolveExited!: (code: number) => void;
  readonly exited = new Promise<number>((r) => {
    this.resolveExited = r;
  });

  /** Stand-ins for a pipe the kernel has already torn down. Bun SWALLOWS a
   *  write to one, so these are how that is reproduced without a real child. */
  writeResult: ((chunk: string) => number | boolean | Promise<number>) | null = null;
  flushResult: (() => number | Promise<number>) | null = null;

  readonly stdin = {
    write: (chunk: string) => {
      this.writes.push(chunk);
      // `true`, which is what Bun 1.4.0's FileSink actually answers for a write
      // it buffered -- measured, for a live pipe and for a dead one alike. It
      // returns a Promise<number> only past the buffer (~512KB).
      return this.writeResult ? this.writeResult(chunk) : true;
    },
    flush: () => {
      this.flushes += 1;
      return this.flushResult ? this.flushResult() : 0;
    },
    end: () => {},
  };
  get stdout(): AsyncIterable<Uint8Array> {
    return this.out;
  }
  get stderr(): AsyncIterable<Uint8Array> {
    return this.err;
  }

  kill(signal?: number | NodeJS.Signals): void {
    this.signals.push(signal ?? "SIGTERM");
  }

  /** Simulate reaping. */
  die(exitCode: number | null, signalCode: string | null = null): void {
    this.exitCode = exitCode;
    this.signalCode = signalCode;
    this.out.close();
    this.err.close();
    this.resolveExited(exitCode ?? 0);
  }
}

interface Harness {
  child: PiChild;
  proc: FakeProc;
  frames: PiFrame[];
  logs: string[];
  exits: PiExit[];
  spawned: SpawnOptions[];
  waits: number[];
  /** Let the stdout/stderr pumps run. */
  settle: () => Promise<void>;
}

function harness(over: Partial<PiSpawnConfig> = {}, waitImpl?: (ms: number) => Promise<void>): Harness {
  const proc = new FakeProc();
  const frames: PiFrame[] = [];
  const logs: string[] = [];
  const exits: PiExit[] = [];
  const spawned: SpawnOptions[] = [];
  const waits: number[] = [];

  const deps: PiChildDeps = {
    spawn: (opts) => {
      spawned.push(opts);
      return proc;
    },
    log: (l) => logs.push(l),
    wait: (ms) => {
      waits.push(ms);
      return waitImpl ? waitImpl(ms) : new Promise<void>(() => {}); // never, by default
    },
  };

  const cfg: PiSpawnConfig = {
    provider: "ollama",
    model: "glm-5.3-flash",
    home: HOME,
    exists: () => true,
    ...over,
  };

  const child = new PiChild(
    cfg,
    { onFrame: (f) => frames.push(f), onExit: (e) => exits.push(e) },
    deps,
  );
  child.start();

  // Two microtask drains: one for the pump to pick the chunk up, one for the
  // dispatch it triggers.
  const settle = async () => {
    for (let i = 0; i < 4; i++) await Promise.resolve();
    await new Promise<void>((r) => setTimeout(r, 0));
  };

  return { child, proc, frames, logs, exits, spawned, waits, settle };
}

/**
 * How a promise ended, as text, with a deadline of its own: `"resolved"`, the
 * stringified rejection, or `"never settled"`.
 *
 * This exists because bun 1.4.0's per-test timeout does NOT cover
 * `await expect(p).rejects.…` -- against a promise that never settles it spins
 * the runner at 100% CPU and prints nothing, so a regression that stops a
 * promise from settling wedges the suite instead of turning it red.
 */
async function settledText(p: Promise<unknown>, ms = 1000): Promise<string> {
  return await Promise.race([
    p.then(() => "resolved", (e: unknown) => String(e)),
    Bun.sleep(ms).then(() => "never settled"),
  ]);
}

/* ------------------------------------------------------------------ */

describe("PiChild spawn", () => {
  test("runs through a login shell, in the workdir, with the detach env", () => {
    const h = harness({ detachPath: "/run/user/1000/ori-detach-9-1" });
    const opts = h.spawned[0];
    expect(opts?.cmd[0]).toBe("sh");
    expect(opts?.cmd[1]).toBe("-lc");
    expect(opts?.cmd[2]).toContain("exec 'pi'");
    expect(opts?.cwd).toBe(`${HOME}/.dotfiles`);
    expect(opts?.env["SHIM_URL"]).toBe("https://ollama.ncym.uk");
    expect(opts?.env["ORI_DETACH_PATH"]).toBe("/run/user/1000/ori-detach-9-1");
  });

  test("start twice throws rather than orphaning the first child", () => {
    const h = harness();
    expect(() => h.child.start()).toThrow(/twice/);
  });
});

describe("PiChild stdout framing", () => {
  test("a multi-line chunk yields two frames", async () => {
    const h = harness();
    h.proc.out.push(
      JSON.stringify({ type: "agent_start" }) +
        "\n" +
        JSON.stringify({ type: "agent_settled" }) +
        "\n",
    );
    await h.settle();
    expect(h.frames.map((f) => f.type)).toEqual(["agent_start", "agent_settled"]);
  });

  test("a chunk split mid-record yields one frame, then the rest", async () => {
    const h = harness();
    const a = JSON.stringify({ type: "agent_start" }) + "\n";
    const b = JSON.stringify({ type: "agent_settled" }) + "\n";
    const joined = a + b;
    const cut = a.length + 8; // partway into the second record

    h.proc.out.push(joined.slice(0, cut));
    await h.settle();
    expect(h.frames.map((f) => f.type)).toEqual(["agent_start"]);

    h.proc.out.push(joined.slice(cut));
    await h.settle();
    expect(h.frames.map((f) => f.type)).toEqual(["agent_start", "agent_settled"]);
  });

  test("a torn line is dropped and logged; the stream keeps going", async () => {
    const h = harness();
    h.proc.out.push('{"type":"agent_st\n' + JSON.stringify({ type: "agent_settled" }) + "\n");
    await h.settle();
    expect(h.frames.map((f) => f.type)).toEqual(["agent_settled"]);
    expect(h.logs.some((l) => l.startsWith("unparseable frame dropped"))).toBe(true);
  });

  test("U+2028 / U+2029 inside a JSON string do NOT split a record", async () => {
    // Why node's readline is banned here (ARCHITECTURE.md rule 5): it treats
    // U+2028 and U+2029 as line terminators, and both are legal RAW inside a
    // JSON string, so readline would tear this one frame into three.
    const text = "before\u2028middle\u2029after";
    const h = harness();
    // Hand-built rather than JSON.stringify'd, so the raw code points really do
    // reach the parser -- JSON.stringify is free to escape them.
    h.proc.out.push('{"type":"message_end","text":"before\u2028middle\u2029after"}\n');
    await h.settle();
    expect(h.frames).toHaveLength(1);
    expect((h.frames[0] as unknown as { text: string }).text).toBe(text);
  });

  test("a multi-byte character split across two chunks is not corrupted", async () => {
    const h = harness();
    const line = JSON.stringify({ type: "message_end", text: "שלום" }) + "\n";
    const bytes = enc.encode(line);
    // Cut inside the first Hebrew letter's two-byte sequence.
    const at = bytes.indexOf(0xd7) + 1;
    h.proc.out.pushBytes(bytes.slice(0, at));
    await h.settle();
    expect(h.frames).toHaveLength(0);
    h.proc.out.pushBytes(bytes.slice(at));
    await h.settle();
    expect((h.frames[0] as unknown as { text: string }).text).toBe("שלום");
  });

  test(
    "one huge frame is scanned once, not re-split on every chunk",
    async () => {
      // A get_entries answer for a long session is exactly this: megabytes in
      // ONE record, delivered 64 KB at a time. Re-splitting the accumulated
      // buffer per chunk is O(n^2) on the host's single thread.
      //
      // decodeLines() is `buffered.split("\n")`, so the sum of the receiver
      // lengths of those calls IS the number of characters the parser scanned.
      // That is measured directly rather than timed, so the bound does not
      // depend on how loaded the machine is.
      const CHUNK = 64 * 1024;
      const body = "x".repeat(CHUNK * 160); // ~10 MB
      const line = JSON.stringify({ type: "message_end", text: body }) + "\n";

      const proto = String.prototype as unknown as Record<string, unknown>;
      const realSplit = proto["split"] as (this: string, ...a: unknown[]) => unknown;
      let scanned = 0;
      proto["split"] = function (this: string, ...args: unknown[]): unknown {
        scanned += this.length;
        return realSplit.apply(this, args);
      };

      const h = harness();
      try {
        for (let i = 0; i < line.length; i += CHUNK) {
          h.proc.out.push(line.slice(i, i + CHUNK));
          await h.settle();
        }
      } finally {
        proto["split"] = realSplit;
      }

      expect(h.frames).toHaveLength(1);
      expect((h.frames[0] as unknown as { text: string }).text).toBe(body);
      // Linear scans the record about once. Quadratic scans ~800 MB for this
      // input, so the 2x bound has two orders of magnitude of headroom and no
      // sensitivity to how the chunks happen to fall.
      expect(scanned).toBeLessThan(line.length * 2);
    },
    30000,
  );

  test("blank lines are ignored", async () => {
    const h = harness();
    h.proc.out.push("\n\n" + JSON.stringify({ type: "agent_settled" }) + "\n\n");
    await h.settle();
    expect(h.frames).toHaveLength(1);
    expect(h.logs.some((l) => l.startsWith("unparseable"))).toBe(false);
  });
});

describe("PiChild stderr", () => {
  test("stderr lines are forwarded to the logger, tail included", async () => {
    const h = harness();
    h.proc.err.push("warn: something\npartial");
    await h.settle();
    expect(h.logs).toContain("stderr: warn: something");
    h.proc.die(0);
    await h.child.kill(0);
    await h.settle();
    expect(h.logs).toContain("stderr: partial");
  });
});

describe("PiChild send / request", () => {
  test("send writes one NDJSON line and flushes it", () => {
    const h = harness();
    h.child.send({ type: "prompt", message: "hi" });
    expect(h.proc.writes).toEqual([JSON.stringify({ type: "prompt", message: "hi" }) + "\n"]);
    expect(h.proc.flushes).toBe(1);
  });

  test("request correlates by id and still forwards the frame", async () => {
    const h = harness();
    const p = h.child.request({ type: "get_state" });

    const sent = JSON.parse(h.proc.writes[0] ?? "{}") as { id?: string; type: string };
    expect(sent.type).toBe("get_state");
    expect(typeof sent.id).toBe("string");

    h.proc.out.push(
      JSON.stringify({
        id: sent.id,
        type: "response",
        command: "get_state",
        success: true,
        data: { sessionId: "s1" },
      }) + "\n",
    );
    const res = await p;
    expect(res.command).toBe("get_state");
    // request() is an extra view of the stream, not a filter on it.
    expect(h.frames).toHaveLength(1);
  });

  test("a failed response resolves -- only a dead child rejects", async () => {
    const h = harness();
    const p = h.child.request({ type: "set_model", provider: "x", modelId: "y" });
    const id = (JSON.parse(h.proc.writes[0] ?? "{}") as { id: string }).id;
    h.proc.out.push(
      JSON.stringify({ id, type: "response", command: "set_model", success: false, error: "nope" }) +
        "\n",
    );
    const res = await p;
    expect(res.success).toBe(false);
  });

  test("an in-flight request rejects when the child dies", async () => {
    const h = harness();
    const p = h.child.request({ type: "get_state" });
    h.proc.die(1, "SIGSEGV");
    // A rejection or a deadline, whichever lands first -- deliberately NOT
    // `await expect(p).rejects.toThrow(...)`. Measured on bun 1.4.0: against a
    // promise that never settles, that form ignores the per-test timeout, third
    // argument and all, and wedges the WHOLE runner at 100% CPU printing
    // nothing. So with the rejection deleted from watchExit this did not go
    // red, it hung -- and a gate that hangs instead of failing is not a gate.
    expect(await settledText(p)).toMatch(/pi exited \(code=1 signal=SIGSEGV\)/);
  });

  test("send after exit throws instead of dropping the prompt silently", async () => {
    const h = harness();
    h.proc.die(0);
    await h.proc.exited;
    await h.settle();
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/not running/);
  });

  /* --------------------------------------------------------------------- *
   * The window the `not running` guard above does NOT cover: `exit` is set by
   * watchExit, i.e. only once `await proc.exited` resolves. A prompt written
   * before that lands on a pipe the kernel has already torn down, and Bun
   * swallows it -- the exact silent drop the guard claims to prevent.
   * --------------------------------------------------------------------- */

  test("a write into a reaped-but-unnoticed pipe is an error, not a silent drop", () => {
    const h = harness();
    // No settle(): the process is reaped (exitCode set) but watchExit has not
    // run yet, so `this.exit` is still null and the `not running` guard above
    // does not fire. Bun answers `true` to this write, exactly as it does to a
    // healthy one -- the process state is the only tell.
    h.proc.die(0);
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/dead pipe/);
  });

  test("a refused write is an error", () => {
    const h = harness();
    h.proc.writeResult = () => false;
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/refused \d+ bytes/);
  });

  test("a partial write is an error", () => {
    // Not a shape Bun 1.4.0 was observed to produce, but the one its own types
    // declare, and the only one where bytes-taken means anything. BYTES, not
    // characters: a Hebrew prompt is twice as long in bytes as in chars.
    const h = harness();
    h.proc.writeResult = (chunk) => Buffer.byteLength(chunk) - 1;
    expect(() => h.child.send({ type: "prompt", message: "שלום" })).toThrow(/\d+ of \d+ bytes/);
  });

  test("an oversized write that fails in flight rejects the request it belonged to", async () => {
    // Anything past the sink's ~512KB buffer -- an attached image -- is taken
    // asynchronously, so send() cannot throw for it either.
    const h = harness();
    h.proc.writeResult = () => Promise.reject(new Error("EPIPE"));
    const p = h.child.request({ type: "get_state" });
    expect(await settledText(p)).toMatch(/write failed.*EPIPE/);
    expect(h.logs.some((l) => l.includes("write failed"))).toBe(true);
  });

  test("a write that throws is reported rather than swallowed", () => {
    const h = harness();
    h.proc.writeResult = () => {
      throw new Error("EPIPE");
    };
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/write failed.*EPIPE/);
  });

  test("a flush that throws is reported rather than swallowed", () => {
    const h = harness();
    h.proc.flushResult = () => {
      throw new Error("EPIPE");
    };
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/flush failed.*EPIPE/);
  });

  test("an async flush failure rejects the request it belonged to", async () => {
    // A FileSink flush may be asynchronous, so this half cannot throw from
    // send(). It must still reach somebody: a request whose bytes never left
    // the process has to fail, not hang. Raced for the same reason as above.
    const h = harness();
    h.proc.flushResult = () => Promise.reject(new Error("EPIPE"));
    const p = h.child.request({ type: "get_state" });
    expect(await settledText(p)).toMatch(/flush failed.*EPIPE/);
    expect(h.logs.some((l) => l.includes("flush failed"))).toBe(true);
  });
});

describe("PiChild exit", () => {
  test("onExit reports exitCode and signalCode, and does not respawn", async () => {
    const h = harness();
    expect(h.child.running).toBe(true);
    h.proc.die(null, "SIGKILL");
    await h.proc.exited;
    await h.settle();
    expect(h.exits).toEqual([{ exitCode: null, signalCode: "SIGKILL" }]);
    expect(h.child.running).toBe(false);
    expect(h.spawned).toHaveLength(1);
  });
});

describe("PiChild kill", () => {
  test("a child that goes on SIGTERM is never SIGKILLed", async () => {
    // wait() here resolves only after the process has already been reaped, which
    // is what the grace race looks like when the child behaves.
    const h = harness({}, async () => {
      await new Promise<void>((r) => setTimeout(r, 20));
    });
    setTimeout(() => h.proc.die(0), 0);
    const exit = await h.child.kill(2000);
    expect(h.proc.signals).toEqual(["SIGTERM"]);
    expect(exit).toEqual({ exitCode: 0, signalCode: null });
  });

  test("a child that ignores SIGTERM gets SIGKILL after the grace period", async () => {
    const h = harness({}, async (ms) => {
      // The grace period elapses with the child still alive; it only dies once
      // SIGKILL lands.
      await new Promise<void>((r) => setTimeout(r, ms));
    });
    const killing = h.child.kill(1);
    // The fake process cannot die on its own -- do it when SIGKILL arrives.
    const poll = setInterval(() => {
      if (h.proc.signals.includes("SIGKILL")) {
        clearInterval(poll);
        h.proc.die(null, "SIGKILL");
      }
    }, 1);
    const exit = await killing;
    expect(h.proc.signals).toEqual(["SIGTERM", "SIGKILL"]);
    expect(exit.signalCode).toBe("SIGKILL");
  });
});
