/**
 * One `pi --mode rpc` child: spawn it, frame its stdio, type its traffic, and
 * report its death. It owns nothing above that line -- it does not queue, does
 * not respawn, does not interpret a single event. The pool decides.
 *
 * Everything with a side effect (spawn, clock) arrives through `PiChildDeps`,
 * so the whole class is testable against a fake child with no process anywhere.
 */

import { decodeLines } from "../protocol";
import {
  buildArgv,
  buildEnv,
  buildShellCommand,
  buildWorkdir,
  type PiSpawnConfig,
} from "./argv";
import { isRpcResponse, type PiFrame, type RpcCommand, type RpcResponse } from "./pi-types";

/* ------------------------------------------------------------------ *
 * The injected process surface -- the subset of Bun.spawn we actually use
 * ------------------------------------------------------------------ */

/** Bun's stdin FileSink. `flush()` is what actually pushes the bytes.
 *
 *  `write` has three return shapes, all measured on Bun 1.4.0: `true` for a
 *  write the sink buffered (including into a pipe whose child is already
 *  reaped), a `Promise<number>` for anything past the sink's buffer (~512KB --
 *  an attached image is exactly this), and a number for a partial take. */
export interface ChildStdin {
  write(chunk: string): number | boolean | Promise<number>;
  flush(): number | Promise<number>;
  end(): void;
}

export interface ChildProcessLike {
  readonly pid: number;
  readonly stdin: ChildStdin;
  readonly stdout: AsyncIterable<Uint8Array>;
  readonly stderr: AsyncIterable<Uint8Array>;
  /** Resolves when the process is reaped. */
  readonly exited: Promise<number>;
  readonly exitCode: number | null;
  readonly signalCode: string | null;
  kill(signal?: number | NodeJS.Signals): void;
}

export interface SpawnOptions {
  cmd: string[];
  cwd: string;
  env: Record<string, string | undefined>;
}

export type SpawnFn = (opts: SpawnOptions) => ChildProcessLike;

export interface PiChildDeps {
  spawn: SpawnFn;
  /** Line-oriented sink for pi's stderr and for this module's own complaints. */
  log: (line: string) => void;
  /** Injected so kill()'s grace period is not a real 2s in a test. */
  wait: (ms: number) => Promise<void>;
}

export const defaultSpawn: SpawnFn = (opts) =>
  Bun.spawn({
    cmd: opts.cmd,
    cwd: opts.cwd,
    env: opts.env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  }) as unknown as ChildProcessLike;

export const defaultPiChildDeps: PiChildDeps = {
  spawn: defaultSpawn,
  log: (line) => console.error("[pi]", line),
  wait: (ms) => new Promise((r) => setTimeout(r, ms)),
};

export interface PiExit {
  exitCode: number | null;
  signalCode: string | null;
}

export interface PiChildHandlers {
  /** Every frame pi writes, in order. Correlated replies are delivered here
   *  TOO -- request() is an extra view of the stream, not a filter on it. */
  onFrame?: (frame: PiFrame) => void;
  onExit?: (exit: PiExit) => void;
}

/* ------------------------------------------------------------------ */

export class PiChild {
  readonly cfg: PiSpawnConfig;
  readonly argv: string[];

  private readonly deps: PiChildDeps;
  private readonly handlers: PiChildHandlers;
  private proc: ChildProcessLike | null = null;
  private pending = new Map<string, (r: RpcResponse) => void>();
  private rejecters = new Map<string, (e: Error) => void>();
  private exit: PiExit | null = null;
  private seq = 0;

  constructor(cfg: PiSpawnConfig, handlers: PiChildHandlers = {}, deps: PiChildDeps = defaultPiChildDeps) {
    this.cfg = cfg;
    this.deps = deps;
    this.handlers = handlers;
    this.argv = buildArgv(cfg);
  }

  get pid(): number {
    return this.proc?.pid ?? -1;
  }

  get running(): boolean {
    return this.proc !== null && this.exit === null;
  }

  /** The exact `sh -lc` line this child was or will be started with. Logged at
   *  spawn, because "which flags did that child actually get" is the first
   *  question every startup bug asks. */
  get command(): string[] {
    return buildShellCommand(this.argv, buildWorkdir(this.cfg));
  }

  start(): void {
    if (this.proc) throw new Error("PiChild.start called twice");
    const cmd = this.command;
    this.deps.log("spawn: " + cmd[2]);
    this.proc = this.deps.spawn({
      cmd,
      cwd: buildWorkdir(this.cfg),
      // The login shell supplies PATH and the keys; these two are ours. Passing
      // them through the spawn env rather than as `VAR=x` prefixes in the shell
      // line (which is what ori-agent did) means they need no quoting and
      // cannot be re-split by the shell.
      env: { ...process.env, ...buildEnv(this.cfg) },
    });

    void this.pumpStdout(this.proc);
    void this.pumpStderr(this.proc);
    void this.watchExit(this.proc);
  }

  /**
   * Fire and forget. Throws if the child is gone -- queueing is the pool's job,
   * and a silent drop here would look like pi ignoring a prompt.
   *
   * The `exit` guard above is not enough on its own. `exit` is set by watchExit,
   * i.e. only once `await proc.exited` resolves, and a write into the window
   * before that is SWALLOWED by Bun -- which is precisely the silent drop the
   * guard claims to prevent. `write`'s return value cannot tell that apart on
   * its own (a dead pipe answers `true`, same as a healthy buffered write), so
   * each of its three shapes is handled separately below. A big write and a
   * flush are both potentially asynchronous, so those halves cannot throw from
   * here; they reject the correlated request instead, and say so on the log
   * either way.
   */
  send(cmd: RpcCommand): void {
    const proc = this.proc;
    if (!proc || this.exit !== null) throw new Error("pi child is not running");

    const line = JSON.stringify(cmd) + "\n";
    const want = Buffer.byteLength(line);
    let took: number | boolean | Promise<number>;
    try {
      took = proc.stdin.write(line);
    } catch (e) {
      throw new Error(`pi stdin write failed: ${String(e)}`);
    }
    if (took instanceof Promise) {
      // Too big for the sink's buffer, so the write is still in flight and its
      // rejection is the only report there will ever be.
      void took.catch((e: unknown) => this.failSend(cmd.id, "write", e));
    } else if (took === false) {
      throw new Error(`pi stdin refused ${want} bytes`);
    } else if (took === true) {
      // Buffered -- by a live sink or by one whose child is already reaped, and
      // the return value does not distinguish them. The process does:
      // `proc.exitCode` is set when Bun reaps, one microtask AHEAD of the
      // watchExit continuation that sets `this.exit`, so this covers the window
      // the guard above cannot. (A child that has died but not yet been reaped
      // is invisible to both; nothing synchronous can see it.)
      if (proc.exitCode !== null || proc.signalCode !== null)
        throw new Error(`pi stdin took ${want} bytes into a dead pipe`);
    } else if (took < want) {
      throw new Error(`pi stdin took ${took} of ${want} bytes`);
    }

    // Without the flush the command sits in userspace and pi waits for a prompt
    // that was, as far as the panel is concerned, sent.
    let flushed: number | Promise<number>;
    try {
      flushed = proc.stdin.flush();
    } catch (e) {
      throw new Error(`pi stdin flush failed: ${String(e)}`);
    }
    if (flushed instanceof Promise) {
      void flushed.catch((e: unknown) => this.failSend(cmd.id, "flush", e));
    }
  }

  /** A write or flush that failed after send() had already returned. Nothing is
   *  left to throw to, so the correlated request is rejected and the rest is
   *  logged -- the one outcome that is never acceptable is neither. */
  private failSend(id: string | undefined, stage: string, e: unknown): void {
    const err = new Error(`pi stdin ${stage} failed: ${String(e)}`);
    this.deps.log(err.message);
    if (id === undefined) return;
    const reject = this.rejecters.get(id);
    if (!reject) return;
    this.pending.delete(id);
    this.rejecters.delete(id);
    reject(err);
  }

  /**
   * Send and wait for the reply pi correlates back by `id`.
   *
   * An id is assigned when the caller did not supply one. `success: false`
   * responses RESOLVE -- they are a legitimate answer ("unknown model", say),
   * and the caller decides what that means. Only a dead child rejects.
   */
  request(cmd: RpcCommand): Promise<RpcResponse> {
    const id = cmd.id ?? `${++this.seq}-${crypto.randomUUID()}`;
    return new Promise<RpcResponse>((resolve, reject) => {
      try {
        this.send({ ...cmd, id });
      } catch (e) {
        reject(e as Error);
        return;
      }
      this.pending.set(id, resolve);
      this.rejecters.set(id, reject);
    });
  }

  /**
   * SIGTERM, then SIGKILL if it is still there after `graceMs`.
   *
   * The signal reaches pi rather than a shell because build_command execs --
   * see buildShellCommand.
   */
  async kill(graceMs = 2000): Promise<PiExit> {
    const proc = this.proc;
    if (!proc) return { exitCode: null, signalCode: null };
    if (this.exit) return this.exit;

    proc.kill("SIGTERM");
    let timedOut = true;
    await Promise.race([
      proc.exited.then(() => {
        timedOut = false;
      }),
      this.deps.wait(graceMs),
    ]);
    if (timedOut && this.exit === null) proc.kill("SIGKILL");
    await proc.exited;
    return this.exit ?? { exitCode: proc.exitCode, signalCode: proc.signalCode };
  }

  /* ---------------------------------------------------------------- */

  private async pumpStdout(proc: ChildProcessLike): Promise<void> {
    // Split on "\n" ONLY. node's readline additionally splits on U+2028/U+2029,
    // which are valid inside a JSON string, so it is not protocol-compliant for
    // pi RPC -- a model that emits a line separator would tear its own frame.
    const dec = new TextDecoder();
    let buf = "";
    try {
      for await (const chunk of proc.stdout) {
        const text = dec.decode(chunk, { stream: true });
        // Only the NEW text can hold a record boundary we have not seen: after
        // every split, `buf` is what came AFTER the last newline, so it has
        // already been scanned and is known to contain none. Without this the
        // whole accumulated buffer was re-split on every 64 KB chunk, and one
        // large frame -- a get_entries answer for a long session is exactly
        // that -- cost O(n^2) on the host's single thread.
        if (!text.includes("\n")) {
          buf += text;
          continue;
        }
        buf += text;
        const { msgs, bad, rest } = decodeLines(buf);
        buf = rest;
        for (const line of bad) {
          // Dropped, never thrown: one torn record must not take down a child
          // that is mid-turn.
          this.deps.log("unparseable frame dropped: " + line.slice(0, 200));
        }
        for (const msg of msgs) this.dispatch(msg as PiFrame);
      }
    } catch (e) {
      this.deps.log("stdout read failed: " + String(e));
    }
  }

  private async pumpStderr(proc: ChildProcessLike): Promise<void> {
    // Drained unconditionally. An undrained pipe fills at 64KB and then BLOCKS
    // the writer -- pi would stop mid-turn with no error anywhere.
    const dec = new TextDecoder();
    let buf = "";
    try {
      for await (const chunk of proc.stderr) {
        buf += dec.decode(chunk, { stream: true });
        const parts = buf.split("\n");
        buf = parts.pop() ?? "";
        for (const line of parts) if (line !== "") this.deps.log("stderr: " + line);
      }
    } catch (e) {
      this.deps.log("stderr read failed: " + String(e));
    }
    if (buf !== "") this.deps.log("stderr: " + buf);
  }

  private async watchExit(proc: ChildProcessLike): Promise<void> {
    await proc.exited;
    this.exit = { exitCode: proc.exitCode, signalCode: proc.signalCode };
    // Anything still waiting for a reply will never get one. Rejecting is the
    // only honest outcome; a hung promise here is how a parked busy turn
    // silently disappears, which docs/specs/multi-session.md forbids.
    const dead = new Error(
      `pi exited (code=${this.exit.exitCode} signal=${this.exit.signalCode})`,
    );
    for (const reject of this.rejecters.values()) reject(dead);
    this.pending.clear();
    this.rejecters.clear();
    this.handlers.onExit?.(this.exit);
  }

  private dispatch(frame: PiFrame): void {
    if (isRpcResponse(frame) && frame.id) {
      const resolve = this.pending.get(frame.id);
      if (resolve) {
        this.pending.delete(frame.id);
        this.rejecters.delete(frame.id);
        resolve(frame);
      }
    }
    this.handlers.onFrame?.(frame);
  }
}
