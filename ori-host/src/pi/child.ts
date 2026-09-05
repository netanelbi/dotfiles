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

/** Bun's stdin FileSink. `flush()` is what actually pushes the bytes. */
export interface ChildStdin {
  write(chunk: string): number;
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

  /** Fire and forget. Throws if the child is gone -- queueing is the pool's job,
   *  and a silent drop here would look like pi ignoring a prompt. */
  send(cmd: RpcCommand): void {
    const proc = this.proc;
    if (!proc || this.exit !== null) throw new Error("pi child is not running");
    proc.stdin.write(JSON.stringify(cmd) + "\n");
    // A FileSink buffers; without this the command sits in userspace and pi
    // waits for a prompt that was, as far as the panel is concerned, sent.
    void proc.stdin.flush();
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
        buf += dec.decode(chunk, { stream: true });
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
