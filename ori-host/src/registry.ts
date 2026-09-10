/**
 * registry.ts -- the host's WRITE side of the peers registry.
 *
 * Reading it is catalog.ts's job and always has been. This module exists for
 * one thing: renaming an agent this host does not own.
 *
 * Ori's own conversations are renamed through pi (`set_session_name`), because
 * the host holds their stdin and because that name also belongs in the resume
 * picker. A terminal pi in another repo, or a delegate the subagent extension
 * spawned, has no such channel -- so the only name that can be given to it is
 * the registry's own `label`, which `peers send` also resolves as an address.
 *
 * THE LOCK PROTOCOL IS SHARED WITH `peers.ts` and must not drift:
 * `<registry>.lock` created with O_EXCL, taken over after 5s as stale, and a
 * write is temp-file-plus-rename so an unlocked reader never sees a torn file.
 * Both sides give up after a deadline rather than block forever, and only the
 * side that actually took the lock removes it.
 */

import { closeSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";

const LOCK_STALE_MS = 5000;
const LOCK_DEADLINE_MS = 2000;

function withLock<T>(file: string, fn: () => T): T {
  const lock = `${file}.lock`;
  const deadline = Date.now() + LOCK_DEADLINE_MS;
  let held = false;
  for (;;) {
    try {
      closeSync(openSync(lock, "wx"));
      held = true;
      break;
    } catch {
      try {
        if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) rmSync(lock, { force: true });
      } catch {
        /* raced with its owner */
      }
      if (Date.now() > deadline) break;
      Atomics.wait(WAIT, 0, 0, 5);
    }
  }
  try {
    return fn();
  } finally {
    if (held) rmSync(lock, { force: true });
  }
}
/** Backing store for the sleeping wait above; never read for its value. */
const WAIT = new Int32Array(new SharedArrayBuffer(4));

/**
 * Set `label` on one row. Returns false when the row is gone, which is not an
 * error worth throwing over -- the agent settled and pruned itself between the
 * panel drawing the list and the user pressing a key.
 */
export function setLabel(file: string, name: string, label: string): boolean {
  return withLock(file, () => {
    let all: Record<string, Record<string, unknown>>;
    try {
      all = JSON.parse(readFileSync(file, "utf-8"));
    } catch {
      return false;
    }
    if (!all[name]) return false;
    all[name] = { ...all[name], label };
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(all, null, 2));
    renameSync(tmp, file);
    return true;
  });
}
