import { describe, expect, test } from "bun:test";

import {
  Pool,
  IDLE_KILL_MS,
  ORPHAN_GRACE_MS,
  MAX_PARKED,
  type Clock,
  type Conversation,
  type ConversationHooks,
  type ConvSpec,
  type Snapshot,
  type TimerHandle,
} from "../src/pool";
import type { HostEvent, Turn } from "../src/protocol";
import { Store, type SessionIndex, type SessionRow, type SessionUpsert } from "../src/store";

/* ------------------------------------------------------------------ *
 * Fakes
 * ------------------------------------------------------------------ */

/** Virtual time. `advance` fires due timers in time order and moves `now` to
 *  each timer's own deadline first, so a callback that re-arms gets the right
 *  base -- which is exactly what the idle clock does. */
class FakeClock implements Clock {
  t = 0;
  #seq = 0;
  #timers = new Map<number, { at: number; fn: () => void }>();

  now(): number {
    return this.t;
  }
  setTimeout(fn: () => void, ms: number): TimerHandle {
    const id = ++this.#seq;
    this.#timers.set(id, { at: this.t + ms, fn });
    return id;
  }
  clearTimeout(handle: TimerHandle): void {
    if (typeof handle === "number") this.#timers.delete(handle);
  }
  get pending(): number {
    return this.#timers.size;
  }
  advance(ms: number): void {
    const target = this.t + ms;
    for (;;) {
      let dueId = -1;
      let due: { at: number; fn: () => void } | null = null;
      for (const [id, timer] of this.#timers) {
        if (timer.at > target) continue;
        if (!due || timer.at < due.at) {
          due = timer;
          dueId = id;
        }
      }
      if (!due) break;
      this.#timers.delete(dueId);
      this.t = due.at;
      due.fn();
    }
    this.t = target;
  }
}

function turn(id: string, text: string): Turn {
  return {
    id,
    role: "user",
    text,
    thinking: "",
    tools: [],
    images: [],
    pending: false,
    delivery: 1,
  };
}

class FakeConv implements Conversation {
  readonly id: string;
  readonly sessionId: string;
  sessionFile: string;
  busy = false;
  childAlive = true;

  turns: Turn[] = [];
  killed: string[] = [];
  failed: string[] = [];
  disposed = false;
  snapshots = 0;

  readonly hooks: ConversationHooks;

  constructor(spec: ConvSpec, hooks: ConversationHooks) {
    this.id = spec.convId;
    this.sessionId = spec.sessionId;
    this.sessionFile = spec.sessionFile || `/s/${spec.sessionId}.jsonl`;
    this.hooks = hooks;
  }

  label(): string {
    return this.turns[0]?.text ?? "";
  }
  turnCount(): number {
    return this.turns.length;
  }
  snapshot(): Snapshot {
    this.snapshots++;
    return {
      t: "snapshot",
      convId: this.id,
      turns: this.turns,
      state: {
        busy: this.busy,
        compacting: false,
        compactPhase: "",
        warm: this.childAlive,
        provider: "ollama",
        model: "glm",
        effort: "",
        thinkingLevel: "low",
        levels: [],
        sessionId: this.sessionId,
        sessionFile: this.sessionFile,
        sessionName: "",
        workdir: "/home/netanel/.dotfiles",
      },
      usage: { input: 0, output: 0, total: 0, contextWindow: 0, estimated: false },
      bg: [],
    };
  }
  killChild(why: string): void {
    this.killed.push(why);
    this.childAlive = false;
    this.hooks.onChildExit();
  }
  failTurn(why: string): void {
    this.failed.push(why);
    this.busy = false;
  }
  dispose(): void {
    this.disposed = true;
    this.childAlive = false;
  }

  /* --- test drivers, standing in for pi frames --- */

  ask(text: string): void {
    this.turns.push(turn(`t${this.turns.length}`, text));
    this.busy = true;
    this.hooks.onActivity();
  }
  frame(): void {
    this.hooks.onActivity();
  }
  settle(): void {
    this.busy = false;
    this.hooks.onActivity();
    this.hooks.onSettled();
  }
  /** The child dies on its own -- a crash, not a kill. */
  crash(): void {
    this.childAlive = false;
    this.hooks.onChildExit();
  }
}

/** Wraps a real Store so a test can prove a code path did NOT touch the disk. */
class CountingIndex implements SessionIndex {
  reads = 0;
  lists = 0;
  writes = 0;
  #inner = new Store();

  upsert(entry: SessionUpsert): void {
    this.writes++;
    this.#inner.upsert(entry);
  }
  list(limit?: number): SessionRow[] {
    this.lists++;
    return this.#inner.list(limit);
  }
  // Not counted: ambiguous() is only consulted on the failure path, after
  // byId() has already returned null, so counting it would double-count one
  // lookup and break the "did not touch the disk" assertions.
  ambiguous(id: string): boolean {
    return this.#inner.ambiguous(id);
  }
  byId(id: string): SessionRow | null {
    this.reads++;
    return this.#inner.byId(id);
  }
  seed(entry: SessionUpsert): void {
    this.#inner.upsert(entry);
  }
}

interface Harness {
  pool: Pool;
  clock: FakeClock;
  store: CountingIndex;
  events: HostEvent[];
  made: FakeConv[];
  /** How many times the factory ran -- i.e. how many cold starts happened. */
  factoryCalls: () => number;
}

function harness(over: { idleKillMs?: number; orphanGraceMs?: number; maxParked?: number } = {}): Harness {
  const clock = new FakeClock();
  const store = new CountingIndex();
  const events: HostEvent[] = [];
  const made: FakeConv[] = [];
  let n = 0;

  const pool = new Pool({
    store,
    factory: (spec, hooks) => {
      const c = new FakeConv(spec, hooks);
      made.push(c);
      return c;
    },
    emit: (ev) => events.push(ev),
    clock,
    newId: () => `id-${++n}`,
    ...over,
  });

  return { pool, clock, store, events, made, factoryCalls: () => made.length };
}

/* ------------------------------------------------------------------ *
 * Parking
 * ------------------------------------------------------------------ */

describe("parking", () => {
  test("parking a busy conversation keeps it busy, with its child and its turn", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("long running question");
    expect(a.busy).toBe(true);

    const b = h.pool.create() as FakeConv;

    expect(h.pool.active).toBe(b);
    // The whole requirement, in four assertions.
    expect(a.busy).toBe(true);
    expect(a.childAlive).toBe(true);
    expect(a.killed).toEqual([]);
    expect(a.failed).toEqual([]);
    expect(a.disposed).toBe(false);
  });

  test("a parked conversation keeps ingesting, and its settle still records it", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    h.pool.create();

    a.turns.push(turn("t1", "the answer"));
    a.settle();

    expect(a.busy).toBe(false);
    expect(h.store.writes).toBe(1);
    const listed = h.pool.list().find((e) => e.id === a.sessionId);
    expect(listed).toMatchObject({ live: true, busy: false, turns: 2, label: "q" });
  });

  test("the picker shows a parked session as live and busy", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("still going");
    h.pool.create();

    const rows = h.pool.list();
    const parked = rows.find((e) => e.id === a.sessionId);
    expect(parked).toMatchObject({ live: true, busy: true });
    // Live conversations sit at the top of the list, per the spec.
    expect(rows.every((e) => e.live)).toBe(true);
  });
});

describe("activate", () => {
  test("is instant: same in-memory turns, no disk read, no new child", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("keep me");
    a.turns.push(turn("t1", "answer"));
    h.pool.create();

    const before = { reads: h.store.reads, factory: h.factoryCalls() };
    h.events.length = 0;

    expect(h.pool.activate(a.id)).toBe(true);

    expect(h.pool.active).toBe(a);
    // No cold resume: nothing was looked up and nothing was constructed.
    expect(h.store.reads).toBe(before.reads);
    expect(h.factoryCalls()).toBe(before.factory);

    // A fresh snapshot carrying the very turns it has been holding all along.
    const snap = h.events.find((e): e is Snapshot => e.t === "snapshot");
    expect(snap).toBeDefined();
    expect(snap!.convId).toBe(a.id);
    expect(snap!.turns).toBe(a.turns); // identity, not a copy read from disk
    expect(snap!.turns.map((t) => t.text)).toEqual(["keep me", "answer"]);
  });

  test("activating an unknown conversation fails without disturbing the active one", () => {
    const h = harness();
    const a = h.pool.create();
    expect(h.pool.activate("nope")).toBe(false);
    expect(h.pool.active).toBe(a);
  });

  test("resume of a session already parked activates it instead of cold-spawning", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    h.pool.create();
    const before = h.factoryCalls();

    const got = h.pool.resume(a.sessionId);

    expect(got).toBe(a);
    expect(h.factoryCalls()).toBe(before);
    expect(a.busy).toBe(true);
  });

  test("a turn STARTING re-emits the session list, so busy is not stale", () => {
    // Reported from the live panel: Ctrl+R while the conversation you are in is
    // working showed it as idle. `sessions` went out on park, settle and
    // child-exit -- every edge except a turn beginning -- so the row you were
    // looking at was the only row that could not say it was running, and
    // parking something else was what appeared to "fix" it.
    const h = harness();
    const a = h.pool.create() as FakeConv;
    const sessionsSeen = () => h.events.filter((e) => e.t === "sessions").length;

    const before = sessionsSeen();
    a.ask("something slow");
    expect(a.busy).toBe(true);
    expect(sessionsSeen()).toBeGreaterThan(before);

    const listed = h.pool.list().find((e) => e.id === a.sessionId);
    expect(listed?.busy).toBe(true);

    // EDGE-triggered: onActivity fires on every frame of a stream, and each
    // list is a store read plus every conversation. Frames while already busy
    // must not re-emit.
    const afterStart = sessionsSeen();
    a.frame();
    a.frame();
    expect(sessionsSeen()).toBe(afterStart);
  });

  test("resume REFUSES an ambiguous prefix even when a LIVE conversation matches it", () => {
    // The bug this pins was found by driving the real panel, not by a test:
    // `ipc call ori resume 0` reported success and silently re-activated the
    // conversation that happened to be active, because the pool's prefix match
    // ran BEFORE the index's ambiguity check and returned its first hit. The
    // index knows every session in the workdir; the pool knows the four it
    // holds, so the pool must never get to decide this.
    const h = harness();
    const live = h.pool.create() as FakeConv;
    // A prefix the live conversation shares with a session it has never seen.
    // Real pi ids are uuidv7, so in one workdir they all share several leading
    // characters -- which is exactly why this stopped being a rare case.
    // Strictly SHORTER than the id: at full length it is an exact match, which
    // short-circuits ahead of the ambiguity check by design.
    const prefix = live.sessionId.slice(0, -1);
    h.store.seed({ id: live.sessionId, file: "/s/live.jsonl", label: "live", at: 9, turns: 1 });
    h.store.seed({ id: `${prefix}-decoy`, file: "/s/decoy.jsonl", label: "decoy", at: 5, turns: 1 });

    expect(() => h.pool.resume(prefix)).toThrow(/ambiguous/);

    // The full id is never ambiguous, and must still reuse the LIVE
    // conversation rather than cold-spawning -- the guard must not break that.
    const before = h.factoryCalls();
    expect(h.pool.resume(live.sessionId)).toBe(live);
    expect(h.factoryCalls()).toBe(before);
  });

  test("resume of a session only on disk cold-spawns from its stored file", () => {
    const h = harness();
    h.store.seed({ id: "sess-old", file: "/s/old.jsonl", label: "old chat", at: 5, turns: 3 });
    const a = h.pool.create() as FakeConv;
    a.ask("q");

    const got = h.pool.resume("sess-old") as FakeConv;

    expect(got.sessionId).toBe("sess-old");
    expect(got.sessionFile).toBe("/s/old.jsonl");
    expect(h.pool.active).toBe(got);
    expect(a.busy).toBe(true); // and the one it replaced is still running
  });

  test("resume of an unknown session throws and parks nothing", () => {
    const h = harness();
    const a = h.pool.create();
    expect(() => h.pool.resume("ghost")).toThrow("no such session: ghost");
    expect(h.pool.active).toBe(a);
  });
});

/* ------------------------------------------------------------------ *
 * Cap
 * ------------------------------------------------------------------ */

describe("parked cap", () => {
  test("defaults are the documented ones", () => {
    expect(MAX_PARKED).toBe(4);
    expect(IDLE_KILL_MS).toBe(600_000);
    expect(ORPHAN_GRACE_MS).toBe(90_000);
  });

  test("evicts the oldest idle one when full", () => {
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 5; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      c.settle();
      h.clock.advance(1000); // each is a little older than the next
      convs.push(c);
    }
    // 1 active + 4 parked is exactly the cap.
    expect(h.pool.parkedCount).toBe(4);
    expect(convs.every((c) => !c.disposed)).toBe(true);

    h.pool.create();

    expect(h.pool.parkedCount).toBe(4);
    expect(convs[0]!.disposed).toBe(true); // the oldest
    expect(convs.slice(1).every((c) => !c.disposed)).toBe(true);
    // It is still resumable from disk.
    expect(h.pool.list().find((e) => e.id === convs[0]!.sessionId)).toMatchObject({
      live: false,
      label: "q0",
    });
  });

  test("never evicts a busy one, even when it is the oldest", () => {
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 5; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      if (i > 0) c.settle(); // the oldest stays mid-turn
      h.clock.advance(1000);
      convs.push(c);
    }

    h.pool.create();

    expect(convs[0]!.busy).toBe(true);
    expect(convs[0]!.disposed).toBe(false);
    expect(convs[1]!.disposed).toBe(true); // the oldest IDLE one went instead
  });

  test("eviction flushes the row at its real recency, not at eviction time", () => {
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 5; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      c.settle();
      h.clock.advance(1000);
      convs.push(c);
    }
    // Well after every one of them went quiet, so a `now` stamp would be
    // unmistakable.
    h.clock.advance(50_000);
    h.pool.create();

    expect(convs[0]!.disposed).toBe(true);
    // The evicted LRU session must stay the OLDEST row. Stamping it `now` would
    // make it the newest, and the panel's boot restore takes sessions[0].
    expect(h.store.list().map((r) => [r.label, r.at])).toEqual([
      ["q4", 4000],
      ["q3", 3000],
      ["q2", 2000],
      ["q1", 1000],
      ["q0", 0],
    ]);
  });

  test("overflows rather than killing a running turn when every parked one is busy", () => {
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 5; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      convs.push(c);
    }
    h.pool.create();

    expect(convs.every((c) => c.busy && !c.disposed)).toBe(true);
    expect(h.pool.parkedCount).toBe(5); // over the cap, deliberately
  });

  test("settling brings an overflowed pool back under the cap", () => {
    // #makeActive used to be the only place the cap was checked, so a pool that
    // overflowed because everything was busy stayed over it until the user
    // switched conversations -- which may be never.
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 5; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      h.clock.advance(1000); // distinct lastActive, so "oldest idle" is decidable
      convs.push(c);
    }
    h.pool.create();
    expect(h.pool.parkedCount).toBe(5);

    // The oldest one stops being busy; it is now the only evictable slot.
    convs[0]!.settle();

    expect(convs[0]!.disposed).toBe(true);
    expect(h.pool.parkedCount).toBe(MAX_PARKED);
    expect(convs.slice(1).every((c) => !c.disposed)).toBe(true);
  });
});

/* ------------------------------------------------------------------ *
 * A parked child dying
 * ------------------------------------------------------------------ */

describe("parked child death", () => {
  test("marks the in-flight turn failed, never silently dropped", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("answer me");
    h.pool.create();

    a.crash();

    expect(a.failed).toHaveLength(1);
    expect(a.failed[0]).toContain("parked");
    expect(a.busy).toBe(false);
    // And it is REPORTED, addressed to the conversation it happened in. Before
    // `error` carried an optional convId there was nothing to address it with,
    // so the host dropped it and the failure surfaced only if the user happened
    // to switch back to that conversation.
    const errs = h.events.filter((e) => e.t === "error");
    expect(errs).toHaveLength(1);
    expect(errs[0]).toMatchObject({ t: "error", convId: a.id });
    // The conversation itself survives -- the panel can still open it.
    expect(a.disposed).toBe(false);
    expect(h.pool.list().find((e) => e.id === a.sessionId)?.live).toBe(true);
  });

  test("an idle parked child dying fails nothing", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();
    h.pool.create();

    a.crash();
    expect(a.failed).toEqual([]);
  });

  test("the ACTIVE conversation's death is left to conversation.ts", () => {
    // Documented boundary: the active conversation is already reporting that
    // frame to the panel itself, so a second failTurn from here would double it.
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.crash();
    expect(a.failed).toEqual([]);
  });
});

/* ------------------------------------------------------------------ *
 * Clocks
 * ------------------------------------------------------------------ */

describe("idle kill (600s)", () => {
  // Every test here keeps a client attached. Without one the 90s orphan grace
  // is the shorter clock and kills the child first -- which is the intended
  // ordering, and is asserted in its own block below.
  function attached(): Harness {
    const h = harness();
    h.pool.clientConnected();
    return h;
  }

  test("fires at 600s and not a millisecond before", () => {
    const h = attached();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();

    h.clock.advance(IDLE_KILL_MS - 1);
    expect(a.killed).toEqual([]);
    expect(a.childAlive).toBe(true);

    h.clock.advance(1);
    expect(a.killed).toEqual(["idle 600s"]);
    expect(a.childAlive).toBe(false);
  });

  test("any frame resets the clock", () => {
    const h = attached();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();

    h.clock.advance(IDLE_KILL_MS - 1000);
    a.frame(); // one more frame, 599s in
    h.clock.advance(IDLE_KILL_MS - 1);
    expect(a.killed).toEqual([]);

    h.clock.advance(1);
    expect(a.killed).toEqual(["idle 600s"]);
  });

  test("never interrupts a running turn", () => {
    const h = attached();
    const a = h.pool.create() as FakeConv;
    a.ask("a turn that has gone quiet without settling");

    h.clock.advance(IDLE_KILL_MS * 3);

    expect(a.killed).toEqual([]);
    expect(a.busy).toBe(true);
    // And the next frame re-arms the clock the fire declined to re-arm.
    a.settle();
    h.clock.advance(IDLE_KILL_MS);
    expect(a.killed).toEqual(["idle 600s"]);
  });

  test("kills a PARKED conversation's child too -- the conversation survives", () => {
    const h = attached();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();
    h.pool.create();

    h.clock.advance(IDLE_KILL_MS);

    expect(a.killed).toEqual(["idle 600s"]);
    expect(a.disposed).toBe(false);
    expect(a.turns).toHaveLength(1); // transcript intact; a later ask cold-spawns
  });
});

describe("orphan reap (90s)", () => {
  test("fires 90s after the last client leaves, and not before", () => {
    const h = harness();
    h.pool.clientConnected();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();

    h.clock.advance(ORPHAN_GRACE_MS * 5);
    expect(a.killed).toEqual([]); // a connected client holds it open

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS - 1);
    expect(a.killed).toEqual([]);

    h.clock.advance(1);
    expect(a.killed).toEqual(["orphan grace"]);
  });

  test("a reconnect inside the grace cancels it", () => {
    const h = harness();
    h.pool.clientConnected();
    const a = h.pool.create() as FakeConv;
    a.settle();

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS - 1);
    h.pool.clientConnected(); // the panel reloaded

    h.clock.advance(ORPHAN_GRACE_MS * 3);
    expect(a.killed).toEqual([]);
  });

  test("a busy conversation is spared, and its settle arms the clock", () => {
    const h = harness();
    h.pool.clientConnected();
    const a = h.pool.create() as FakeConv;
    a.ask("still running");

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS * 4);
    expect(a.killed).toEqual([]); // the reconnect case: keep the child

    a.settle();
    h.clock.advance(ORPHAN_GRACE_MS - 1);
    expect(a.killed).toEqual([]);
    h.clock.advance(1);
    expect(a.killed).toEqual(["orphan grace"]);
  });

  test("one busy conversation does not keep an idle neighbour alive", () => {
    // ori-agent:496 held grace_timer on the SESSION. A pool-wide clock that
    // refused to arm while ANY conversation was busy let one long turn keep
    // every other orphaned child resident for the length of it.
    const h = harness();
    h.pool.clientConnected();
    const busy = h.pool.create() as FakeConv;
    busy.ask("running");
    const idle = h.pool.create() as FakeConv;
    idle.ask("q");
    idle.settle();

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS - 1);
    expect(idle.killed).toEqual([]);
    h.clock.advance(1);
    expect(idle.killed).toEqual(["orphan grace"]);
    // ...and the busy one is untouched: its own clock has not started.
    expect(busy.killed).toEqual([]);
    expect(busy.busy).toBe(true);

    // It still gets its full grace, from its own settle.
    busy.settle();
    h.clock.advance(ORPHAN_GRACE_MS - 1);
    expect(busy.killed).toEqual([]);
    h.clock.advance(1);
    expect(busy.killed).toEqual(["orphan grace"]);
    // Once each, never twice.
    expect(idle.killed).toEqual(["orphan grace"]);
  });

  test("two clients: the grace only starts when the second one leaves", () => {
    const h = harness();
    h.pool.clientConnected();
    h.pool.clientConnected();
    const a = h.pool.create() as FakeConv;
    a.settle();

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS * 2);
    expect(a.killed).toEqual([]);

    h.pool.clientDisconnected();
    h.clock.advance(ORPHAN_GRACE_MS);
    expect(a.killed).toEqual(["orphan grace"]);
  });
});

describe("shutdown", () => {
  test("records and disposes everything, and leaves no timer behind", () => {
    const h = harness();
    const a = h.pool.create() as FakeConv;
    a.ask("q");
    a.settle();
    const b = h.pool.create() as FakeConv;

    h.pool.shutdown();

    expect(a.disposed).toBe(true);
    expect(b.disposed).toBe(true);
    expect(h.pool.active).toBeNull();
    expect(h.clock.pending).toBe(0);
    expect(h.store.list().map((r) => r.label)).toEqual(["q"]);
  });

  test("preserves the order the sessions were last active in", () => {
    const h = harness();
    const convs: FakeConv[] = [];
    for (let i = 0; i < 3; i++) {
      const c = h.pool.create() as FakeConv;
      c.ask(`q${i}`);
      c.settle();
      h.clock.advance(1000);
      convs.push(c);
    }
    h.clock.advance(50_000);

    h.pool.shutdown();

    // Flattening all three to `now` would leave ORDER BY at DESC to fall back on
    // rowid, which returns the OLDEST first -- and that is what the panel would
    // reopen after a restart.
    expect(h.store.list().map((r) => [r.label, r.at])).toEqual([
      ["q2", 2000],
      ["q1", 1000],
      ["q0", 0],
    ]);
  });
});
