/**
 * The steer-detach side channel (ori-agent:566-657).
 *
 * When a question is steered while a bash call is in flight, the call's
 * auto-background timer is re-armed to a short grace period so the tool gets
 * out of the way instead of holding the turn. There is no RPC for that, so the
 * request goes through a file a pi EXTENSION watches -- which is why the record
 * layout below is a contract with another program and must be reproduced
 * exactly.
 *
 * ONE FILE PER CHILD, not one per host: a shared path would detach the call in
 * flight in every session at once, so a steer in the conversation you are
 * looking at would background a build in the one you parked.
 *
 * The whole thing is best effort. No file means no env var, which means the
 * extension never arms and every bash call behaves exactly as it did before any
 * of this existed.
 */

import { openSync, writeSync, closeSync, writeFileSync, unlinkSync, constants } from "node:fs";
import { Buffer } from "node:buffer";

/**
 * Fixed record width. Every write is an overwrite of these same bytes and never
 * a grow, and the padding is what keeps "same width" true when `seq` gains a
 * digit -- without it a shorter record leaves the tail of the longer one behind
 * and the JSON does not parse.
 */
export const DETACH_RECORD = 96;

export interface DetachRecord {
  seq: number;
  graceMs: number;
  pid: number;
}

/**
 * Space-padded to exactly DETACH_RECORD. Returns null when the JSON does not
 * fit, which the caller must treat as "drop the request" -- a truncated record
 * is unparseable on the other side.
 */
export function encodeRecord(rec: DetachRecord): Uint8Array | null {
  const json = JSON.stringify(rec);
  const buf = Buffer.from(json, "utf8");
  if (buf.length > DETACH_RECORD) return null;
  const out = Buffer.alloc(DETACH_RECORD, 0x20); // ljust: pad with spaces
  buf.copy(out);
  return out;
}

/** The reader's half, kept here so the two stay in step and the test can prove
 *  the round trip. Trailing padding is whitespace, which JSON.parse ignores. */
export function decodeRecord(bytes: Uint8Array): DetachRecord | null {
  try {
    const v: unknown = JSON.parse(Buffer.from(bytes).toString("utf8"));
    if (v === null || typeof v !== "object") return null;
    const r = v as Record<string, unknown>;
    if (typeof r["seq"] !== "number") return null;
    return {
      seq: r["seq"],
      graceMs: typeof r["graceMs"] === "number" ? r["graceMs"] : 0,
      pid: typeof r["pid"] === "number" ? r["pid"] : 0,
    };
  } catch {
    return null;
  }
}

/** Seeded with seq 0 so the extension has a baseline to compare the first real
 *  request against, and at FULL WIDTH from the start so no later write grows
 *  the file. */
export function seedRecord(): Uint8Array {
  return encodeRecord({ seq: 0, graceMs: 0, pid: 0 })!;
}

export interface DetachIo {
  create(path: string, bytes: Uint8Array): void;
  /** Overwrite in place from offset 0, O_WRONLY with NO O_TRUNC, ONE write. */
  overwrite(path: string, bytes: Uint8Array): void;
  remove(path: string): void;
}

export const defaultDetachIo: DetachIo = {
  create(path, bytes) {
    writeFileSync(path, bytes);
  },
  overwrite(path, bytes) {
    // O_WRONLY, deliberately without O_TRUNC.
    //
    // `open(path, "w")` truncates and THEN writes, and bun's fs.watch delivers
    // ONE event per write, not two. Measured: 12 writes -> 12 fires, 6 of which
    // read an empty file, and the fire that landed on the truncate was the only
    // one there was. 21 of 30 detach requests were lost that way -- invisibly,
    // because the call just runs its normal timeout.
    //
    // Never renamed into position either: an inotify watch follows the inode,
    // so a rename would leave the extension watching a file nobody writes to
    // again, silently, and only from the second request onward.
    const fd = openSync(path, constants.O_WRONLY);
    try {
      writeSync(fd, bytes, 0, bytes.length, 0);
    } finally {
      closeSync(fd);
    }
  },
  remove(path) {
    try {
      unlinkSync(path);
    } catch {
      // Already gone is the outcome we wanted.
    }
  },
};

/** Per-host counter, so two children of the same host get different paths. */
let spawnSeq = 0;

export interface DetachOptions {
  runtimeDir: string;
  /** The HOST's pid, which only names the file. */
  hostPid?: number;
  io?: DetachIo;
  onError?: (why: string) => void;
}

export class DetachChannel {
  readonly path: string;
  readonly #io: DetachIo;
  readonly #onError: (why: string) => void;
  #seq = 0;

  private constructor(path: string, io: DetachIo, onError: (why: string) => void) {
    this.path = path;
    this.#io = io;
    this.#onError = onError;
  }

  /**
   * Create the file and hand back the channel, or null if it could not be made.
   *
   * Created BEFORE the child exists, because fs.watch() on a missing path
   * throws -- the extension attaches its watcher once, at load, and there is no
   * second chance.
   */
  static open(opts: DetachOptions): DetachChannel | null {
    const io = opts.io ?? defaultDetachIo;
    const onError = opts.onError ?? (() => {});
    const pid = opts.hostPid ?? process.pid;
    const path = `${opts.runtimeDir}/ori-detach-${pid}-${++spawnSeq}`;
    try {
      io.create(path, seedRecord());
    } catch (e) {
      onError(`detach file unavailable, steer-detach is off for this child: ${String(e)}`);
      return null;
    }
    return new DetachChannel(path, io, onError);
  }

  /**
   * Ask this child's in-flight bash calls to re-arm to `graceMs`.
   *
   * `seq` is what makes yesterday's request harmless: fs.watch fires on any
   * touch of the file, so the request has to carry something the reader can
   * compare, and a counter that only goes up means a re-read of unchanged
   * content detaches nothing.
   *
   * `childPid` is what stops a steer aimed at Ori from backgrounding a
   * SUBAGENT's work. Subagents are child pi processes, they inherit the env var
   * and load the same extension, so they watch this very file: with no pid in
   * the record, one steer detached a subagent's build three levels down that
   * nobody had steered. The extension compares it against its own process.pid,
   * so a grandchild is inert.
   */
  detach(graceMs: number, childPid: number): void {
    const bytes = encodeRecord({ seq: ++this.#seq, graceMs, pid: childPid });
    if (!bytes) {
      this.#onError(`detach record over ${DETACH_RECORD} bytes, dropped`);
      return;
    }
    try {
      this.#io.overwrite(this.path, bytes);
    } catch (e) {
      this.#onError(`detach write failed: ${String(e)}`);
    }
  }

  close(): void {
    this.#io.remove(this.path);
  }
}
