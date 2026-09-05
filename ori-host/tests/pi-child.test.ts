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

  readonly stdin = {
    write: (chunk: string) => {
      this.writes.push(chunk);
      return chunk.length;
    },
    flush: () => {
      this.flushes += 1;
      return 0;
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
    await expect(p).rejects.toThrow(/pi exited \(code=1 signal=SIGSEGV\)/);
  });

  test("send after exit throws instead of dropping the prompt silently", async () => {
    const h = harness();
    h.proc.die(0);
    await h.proc.exited;
    await h.settle();
    expect(() => h.child.send({ type: "prompt", message: "hi" })).toThrow(/not running/);
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
