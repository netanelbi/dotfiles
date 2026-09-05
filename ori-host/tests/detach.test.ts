import { test, expect } from "bun:test";
import { mkdtempSync, readFileSync, existsSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  DETACH_RECORD,
  DetachChannel,
  decodeRecord,
  encodeRecord,
  seedRecord,
} from "../src/detach";

test("a record is exactly 96 bytes and round-trips", () => {
  const bytes = encodeRecord({ seq: 7, graceMs: 1500, pid: 424242 });
  expect(bytes).not.toBeNull();
  expect(bytes!.length).toBe(DETACH_RECORD);
  expect(decodeRecord(bytes!)).toEqual({ seq: 7, graceMs: 1500, pid: 424242 });
});

test("the width does not change when seq gains a digit", () => {
  // The padding is what makes "same width" true. Without it a shorter record
  // leaves the tail of the longer one behind and the JSON does not parse.
  const small = encodeRecord({ seq: 9, graceMs: 500, pid: 1 })!;
  const big = encodeRecord({ seq: 1000000, graceMs: 500, pid: 999999 })!;
  expect(small.length).toBe(DETACH_RECORD);
  expect(big.length).toBe(DETACH_RECORD);
  expect(seedRecord().length).toBe(DETACH_RECORD);
  expect(decodeRecord(seedRecord())?.seq).toBe(0);
});

test("a record that would not fit is refused rather than truncated", () => {
  // Unreachable with real values -- three plausible integers plus the keys come
  // to ~40 bytes -- but a truncated record is unparseable on the other side, so
  // the guard drops the request instead. Full-width floats are the only way to
  // make three numbers exceed 96 bytes.
  const wide = -1.2345678901234567e-300;
  expect(encodeRecord({ seq: wide, graceMs: wide, pid: wide })).toBeNull();
});

test("writing a shorter record leaves no tail of the longer one", () => {
  const dir = mkdtempSync(join(tmpdir(), "ori-detach-"));
  try {
    const ch = DetachChannel.open({ runtimeDir: dir, hostPid: 1234 })!;
    expect(ch).not.toBeNull();
    expect(existsSync(ch.path)).toBe(true);
    expect(statSync(ch.path).size).toBe(DETACH_RECORD);

    ch.detach(60000, 999999); // long
    ch.detach(1, 7); // short, over the same bytes

    const bytes = readFileSync(ch.path);
    expect(bytes.length).toBe(DETACH_RECORD);
    expect(decodeRecord(bytes)).toEqual({ seq: 2, graceMs: 1, pid: 7 });

    ch.close();
    expect(existsSync(ch.path)).toBe(false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("seq only ever goes up, so a re-read of unchanged content detaches nothing", () => {
  const dir = mkdtempSync(join(tmpdir(), "ori-detach-"));
  try {
    const ch = DetachChannel.open({ runtimeDir: dir, hostPid: 1234 })!;
    const seqs: number[] = [];
    for (let i = 0; i < 3; i++) {
      ch.detach(500, 42);
      seqs.push(decodeRecord(readFileSync(ch.path))!.seq);
    }
    expect(seqs).toEqual([1, 2, 3]);
    ch.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("two channels of one host get different files", () => {
  const dir = mkdtempSync(join(tmpdir(), "ori-detach-"));
  try {
    // A shared path would detach the call in flight in EVERY session at once.
    const a = DetachChannel.open({ runtimeDir: dir, hostPid: 1234 })!;
    const b = DetachChannel.open({ runtimeDir: dir, hostPid: 1234 })!;
    expect(a.path).not.toBe(b.path);
    a.close();
    b.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an unwritable runtime dir turns the channel off instead of throwing", () => {
  const said: string[] = [];
  const ch = DetachChannel.open({
    runtimeDir: "/nonexistent-dir-for-ori-detach",
    onError: (w) => said.push(w),
  });
  expect(ch).toBeNull();
  expect(said[0]).toContain("steer-detach is off");
});
