/**
 * N conversations, one active, the rest parked.
 *
 * The requirement is docs/specs/multi-session.md, and its one sentence that
 * shapes everything here is: **switching sessions must never stop a running
 * turn.** So parking is bookkeeping and nothing else -- a parked conversation
 * keeps its pi child, keeps ingesting events, keeps filling its own turn list.
 * It simply is not the one being rendered.
 *
 * The two lifetime clocks come from the Python broker and are kept to the
 * second:
 *   - 600 s idle -> kill the child (ori-agent:269). The conversation and its
 *     transcript survive; a later ask cold-spawns.
 *   - 90 s after the last client disconnects -> kill children (ori-agent:426).
 *     A BUSY conversation is spared, exactly as the broker spared a busy orphan,
 *     because that is the case reconnect exists for -- and, as in the broker,
 *     only ITSELF: the clock is per conversation (ori-agent:496).
 *
 * Both clocks are timers reset by events, never polls.
 *
 * The clock and the conversation factory are injected so all of this is
 * testable with no child process and no wall time.
 */

import type { HostEvent, SessionEntry } from "./protocol";
import type { SessionIndex } from "./store";

/** ori-agent:269 -- long enough to cover a back-and-forth, short enough that a
 *  stray question does not leave 200 MB resident for the rest of the day. */
export const IDLE_KILL_MS = 600_000;

/** ori-agent:426 -- a panel reload re-hellos within a second or two, so this
 *  never fires for a live UI; it only bounds the lifetime of conversations
 *  nobody can adopt any more. */
export const ORPHAN_GRACE_MS = 90_000;

/** docs/specs/multi-session.md: "Cap parked sessions at 4". */
export const MAX_PARKED = 4;

/* ------------------------------------------------------------------ *
 * Injected seams
 * ------------------------------------------------------------------ */

export type TimerHandle = unknown;

export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): TimerHandle;
  clearTimeout(handle: TimerHandle): void;
}

export const systemClock: Clock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

export type Snapshot = Extract<HostEvent, { t: "snapshot" }>;

/**
 * What the pool needs from a conversation. conversation.ts implements this; the
 * pool never looks inside a turn, never parses a pi frame, and never touches a
 * child except through `killChild`.
 *
 * NOTE FOR conversation.ts: `busy` must already be false by the time
 * `onSettled` fires, and `childAlive` false by the time `onChildExit` fires --
 * the pool reads both from inside those callbacks.
 */
export interface Conversation {
  /** Stable for the life of the conversation, across child restarts. */
  readonly id: string;
  /** The pi session id. `pi --session-id <id>` is idempotent, so this is minted
   *  up front and one conversation maps to one session id and one index row. */
  readonly sessionId: string;
  /** Path of the pi JSONL. Empty until pi reports it. */
  readonly sessionFile: string;
  readonly busy: boolean;
  readonly childAlive: boolean;

  /** Index-row material. Empty label means "nothing has been asked in it yet". */
  label(): string;
  turnCount(): number;

  /** A complete, current snapshot for the panel. Must be cheap: activate()
   *  calls it and activate() has to feel instant. */
  snapshot(): Snapshot;

  /** Drop the pi child. Turns and transcript survive. */
  killChild(why: string): void;
  /** Mark the in-flight turn FAILED. Never silently dropped. */
  failTurn(why: string): void;
  /** Free everything: this conversation is leaving memory for disk-resume only. */
  dispose(): void;
}

/** The pool's callbacks into a conversation's event stream. */
export interface ConversationHooks {
  /** Any pi frame, either direction. Resets the idle clock. */
  onActivity(): void;
  /** agent_settled -- the idle signal, NOT agent_end. */
  onSettled(): void;
  /** The pi child exited, for any reason. */
  onChildExit(): void;
}

export interface ConvSpec {
  convId: string;
  sessionId: string;
  /** Empty for a fresh conversation; the JSONL path when resuming from disk. */
  sessionFile: string;
}

export type ConvFactory = (spec: ConvSpec, hooks: ConversationHooks) => Conversation;

export interface PoolOptions {
  store: SessionIndex;
  factory: ConvFactory;
  /** Where snapshots and session lists go. main.ts fans this out to clients. */
  emit: (ev: HostEvent) => void;
  clock?: Clock;
  idleKillMs?: number;
  orphanGraceMs?: number;
  maxParked?: number;
  /** Injectable so tests are not at the mercy of a real UUID. */
  newId?: () => string;
}

interface Slot {
  conv: Conversation;
  /** Pool-owned, so eviction order does not depend on the conversation telling
   *  the truth about its own clock. */
  lastActive: number;
  idle: TimerHandle | null;
  /** PER-SESSION, exactly as ori-agent:496 had it (`Session.grace_timer`). One
   *  pool-wide clock meant a single long turn anywhere kept every other
   *  conversation's child alive indefinitely past the 90 s grace. */
  grace: TimerHandle | null;
  /** Last `busy` the pool told clients about, so a change is edge-triggered. */
  busySeen: boolean;
}

/* ------------------------------------------------------------------ *
 * Pool
 * ------------------------------------------------------------------ */

export class Pool {
  #slots = new Map<string, Slot>();
  #activeId = "";
  #clients = 0;

  #store: SessionIndex;
  #factory: ConvFactory;
  #emit: (ev: HostEvent) => void;
  #clock: Clock;
  #idleMs: number;
  #graceMs: number;
  #maxParked: number;
  #newId: () => string;

  constructor(opts: PoolOptions) {
    this.#store = opts.store;
    this.#factory = opts.factory;
    this.#emit = opts.emit;
    this.#clock = opts.clock ?? systemClock;
    this.#idleMs = opts.idleKillMs ?? IDLE_KILL_MS;
    this.#graceMs = opts.orphanGraceMs ?? ORPHAN_GRACE_MS;
    this.#maxParked = opts.maxParked ?? MAX_PARKED;
    this.#newId = opts.newId ?? (() => crypto.randomUUID());
  }

  /* ---------------------------------------------------------- accessors */

  get active(): Conversation | null {
    return this.#slots.get(this.#activeId)?.conv ?? null;
  }

  get activeId(): string {
    return this.#activeId;
  }

  get parkedCount(): number {
    return this.#slots.size - (this.#activeId === "" ? 0 : 1);
  }

  /* ------------------------------------------------------------- create */

  /** Ctrl+N. Parks the current conversation -- never stops it. */
  create(): Conversation {
    this.#park();
    // Minting the session id here rather than waiting for pi is what lets the
    // index row exist before the first turn settles.
    const conv = this.#spawn({ convId: this.#newId(), sessionId: this.#newId(), sessionFile: "" });
    this.#makeActive(conv.id);
    return conv;
  }

  /**
   * Ctrl+R on a past session. Parks the current one either way.
   *
   * If that session is already in memory -- parked, possibly mid-turn -- this
   * is just an activate: no disk read, no second child for the same session id.
   */
  resume(sessionId: string): Conversation {
    // An EXACT id can never be ambiguous, so it short-circuits everything.
    const exact = this.#findBySessionId(sessionId, true);
    if (exact) {
      this.activate(exact.conv.id);
      return exact.conv;
    }

    // Ambiguity is decided against the INDEX, before any prefix matching, and
    // that ordering is the fix. The index knows all 200+ sessions in the
    // workdir; the pool knows the 4 it is holding. Checking the pool first
    // meant one live conversation whose id happened to start with the typed
    // prefix won outright, even when the prefix matched two hundred others --
    // a resume that looks successful and opens the wrong conversation.
    if (this.#store.ambiguous(sessionId)) {
      throw new Error(`ambiguous session id: ${sessionId} matches more than one -- use more characters`);
    }

    const held = this.#findBySessionId(sessionId, false);
    if (held) {
      this.activate(held.conv.id);
      return held.conv;
    }
    const row = this.#store.byId(sessionId);
    if (!row) throw new Error(`no such session: ${sessionId}`);

    this.#park();
    const conv = this.#spawn({
      convId: this.#newId(),
      sessionId: row.id,
      sessionFile: row.file,
    });
    this.#makeActive(conv.id);
    return conv;
  }

  /**
   * Switch to a conversation already in memory. Instant by construction: no
   * factory call, no store lookup, no transcript read -- just a fresh snapshot
   * of state the pool has been holding all along.
   */
  activate(convId: string): boolean {
    const slot = this.#slots.get(convId);
    if (!slot) return false;
    if (convId === this.#activeId) {
      this.#emit(slot.conv.snapshot());
      return true;
    }
    this.#park();
    this.#makeActive(convId);
    return true;
  }

  #spawn(spec: ConvSpec): Conversation {
    // The hooks close over spec.convId, not over `conv`: a factory that fires a
    // hook synchronously would otherwise hit the temporal dead zone.
    const conv = this.#factory(spec, {
      onActivity: () => this.#touch(spec.convId),
      onSettled: () => this.#settled(spec.convId),
      onChildExit: () => this.#childExit(spec.convId),
    });
    this.#slots.set(spec.convId, { conv, lastActive: this.#clock.now(), idle: null, grace: null, busySeen: conv.busy });
    this.#touch(spec.convId);
    return conv;
  }

  #makeActive(convId: string): void {
    this.#activeId = convId;
    const slot = this.#slots.get(convId);
    if (slot) this.#emit(slot.conv.snapshot());
    this.#enforceCap();
    this.#emitSessions();
  }

  /**
   * Park the active conversation.
   *
   * This is deliberately almost empty, and that emptiness IS the feature: no
   * abort, no kill, no timer change. The child keeps running and the turn
   * finishes in the background.
   */
  #park(): void {
    this.#activeId = "";
  }

  /* --------------------------------------------------------------- cap */

  /** Evict down to the cap, oldest idle first. A busy conversation is never
   *  evicted; if every parked one is busy the pool overflows rather than
   *  killing a running turn. */
  #enforceCap(): void {
    while (this.parkedCount > this.#maxParked) {
      let victim: Slot | null = null;
      for (const slot of this.#slots.values()) {
        if (slot.conv.id === this.#activeId) continue;
        if (slot.conv.busy) continue;
        if (!victim || slot.lastActive < victim.lastActive) victim = slot;
      }
      if (!victim) return;
      this.#evict(victim);
    }
  }

  #evict(slot: Slot): void {
    // Flush the row first: after this it exists on disk only, and the picker
    // has to be able to resume it -- at its real recency, not at eviction time.
    this.#record(slot.conv, slot.lastActive);
    this.#clearTimers(slot);
    this.#slots.delete(slot.conv.id);
    slot.conv.dispose();
  }

  #clearTimers(slot: Slot): void {
    if (slot.idle !== null) this.#clock.clearTimeout(slot.idle);
    slot.idle = null;
    if (slot.grace !== null) this.#clock.clearTimeout(slot.grace);
    slot.grace = null;
  }

  /* ------------------------------------------------------------- clocks */

  #touch(convId: string): void {
    const slot = this.#slots.get(convId);
    if (!slot) return;
    slot.lastActive = this.#clock.now();
    // A timer cancelled and recreated on every frame is still a timer; nothing
    // is being polled (ori-agent.touch_idle).
    if (slot.idle !== null) this.#clock.clearTimeout(slot.idle);
    slot.idle = this.#clock.setTimeout(() => this.#idleFire(convId), this.#idleMs);

    // A turn STARTING changes the session list, and nothing else noticed.
    // `sessions` went out on park, settle and child-exit -- every edge except
    // the one where a conversation begins working. So the picker held
    // `busy: false` for the conversation you were IN, from the moment you asked
    // until it answered: the row you were looking at was the one row that could
    // not say it was running, and parking something else was what "fixed" it,
    // because that re-listed.
    //
    // Edge-triggered off a remembered value rather than emitted from here
    // directly: onActivity fires on every frame of a stream, and the list is
    // every conversation plus a store read.
    if (slot.conv.busy !== slot.busySeen) {
      slot.busySeen = slot.conv.busy;
      this.#emitSessions();
    }
  }

  #idleFire(convId: string): void {
    const slot = this.#slots.get(convId);
    if (!slot) return;
    slot.idle = null;
    // A turn cannot be interrupted by the clock. In practice a running turn
    // resets it constantly; this is the guard for a turn gone quiet without
    // settling. Not re-armed here -- the next frame re-arms it.
    if (slot.conv.busy || !slot.conv.childAlive) return;
    slot.conv.killChild(`idle ${Math.round(this.#idleMs / 1000)}s`);
  }

  /* ------------------------------------------------------------- events */

  #settled(convId: string): void {
    const slot = this.#slots.get(convId);
    if (!slot) return;
    this.#record(slot.conv, this.#clock.now());
    // The cap refuses to evict a busy conversation, so a pool that overflowed
    // while every parked one was mid-turn can only come back under it when one
    // of them stops. #makeActive is the only other caller and may not run again
    // for hours -- until then the pool holds more children than the cap allows.
    this.#enforceCap();
    this.#emitSessions();
    // A busy orphan could not arm its own grace clock when its client left. It
    // can now (ori-agent.check_orphan).
    if (this.#slots.has(convId)) this.#checkOrphanFor(slot);
  }

  #childExit(convId: string): void {
    const slot = this.#slots.get(convId);
    if (!slot) return;
    // The active conversation owns its own child's death -- conversation.ts is
    // already handling that frame and reporting it to the panel. The pool's job
    // is the PARKED case, which nothing else is watching: a parked busy child
    // that dies must show as failed, never silently dropped
    // (docs/specs/multi-session.md).
    if (convId !== this.#activeId && slot.conv.busy) {
      const why = "pi exited while this conversation was parked";
      slot.conv.failTurn(why);
      // Addressed to the conversation it happened in. failTurn marks the turn,
      // which the panel sees on its next snapshot -- i.e. only if the user
      // happens to switch back. This is the part that arrives now, and it can
      // only be routed because `error` carries an optional convId (protocol.ts).
      this.#emit({ t: "error", convId, text: why });
    }
    // Same reason as #settled: the exit is what made this one evictable.
    this.#enforceCap();
    this.#emitSessions();
    // Its turn is over one way or the other, so its orphan clock may now be due.
    if (this.#slots.has(convId)) this.#checkOrphanFor(slot);
  }

  /* -------------------------------------------------------- client count */

  clientConnected(): void {
    this.#clients++;
    this.#cancelGrace();
  }

  clientDisconnected(): void {
    if (this.#clients > 0) this.#clients--;
    this.#checkOrphan();
  }

  get clients(): number {
    return this.#clients;
  }

  #checkOrphan(): void {
    for (const slot of this.#slots.values()) this.#checkOrphanFor(slot);
  }

  /**
   * Arm ONE conversation's grace clock, gated on ITS OWN busy flag.
   *
   * ori-agent held `grace_timer` on the Session, not on the broker, and that
   * distinction is the whole bug this shape fixes: a pool-wide clock that
   * refused to arm while any conversation was busy let a single half-hour turn
   * keep every other orphaned child resident for the length of it, seven times
   * over the ten-minute idle kill that was supposed to be the backstop.
   *
   * A busy conversation is still spared -- that is what reconnect is for -- but
   * only its own; its settle calls back in here (ori-agent.check_orphan).
   */
  #checkOrphanFor(slot: Slot): void {
    if (this.#clients > 0) return;
    if (slot.conv.busy) return;
    // Nothing to reap. ori-agent's check_orphan returns here too (`if self.pi is
    // None`), and without it every reap re-armed a second clock through the
    // onChildExit its own kill produced.
    if (!slot.conv.childAlive) return;
    if (slot.grace !== null) return; // already counting down
    const convId = slot.conv.id;
    slot.grace = this.#clock.setTimeout(() => this.#reap(convId), this.#graceMs);
  }

  #cancelGrace(): void {
    for (const slot of this.#slots.values()) {
      if (slot.grace === null) continue;
      this.#clock.clearTimeout(slot.grace);
      slot.grace = null;
    }
  }

  #reap(convId: string): void {
    const slot = this.#slots.get(convId);
    if (!slot) return;
    slot.grace = null;
    if (this.#clients > 0) return;
    if (slot.conv.busy) return; // never interrupt a turn
    if (slot.conv.childAlive) slot.conv.killChild("orphan grace");
  }

  /* ------------------------------------------------------------- index */

  /**
   * `at` is passed in, never taken from the clock here, because two of the three
   * callers are flushes rather than activity: eviction and shutdown write a row
   * for a conversation that has been idle for a while. Stamping `now` there
   * would make the LEAST recently used session the newest row, and the panel's
   * boot restore takes `sessions[0]` -- so a restart would reopen the
   * conversation the user had just abandoned. Only #settled passes the clock.
   */
  #record(conv: Conversation, at: number): void {
    const label = conv.label();
    // A conversation with nothing asked in it is not worth offering
    // (PiSession.recordSession), and pi has not named the file yet either.
    if (label === "" || conv.sessionFile === "") return;
    this.#store.upsert({
      id: conv.sessionId,
      file: conv.sessionFile,
      label,
      at,
      turns: conv.turnCount(),
    });
  }

  /**
   * `exactOnly` splits the two halves resume() needs in a different order: the
   * exact match runs BEFORE the index's ambiguity check (a full id cannot be
   * ambiguous), the prefix match runs after it.
   */
  #findBySessionId(sessionId: string, exactOnly = false): Slot | null {
    if (sessionId === "") return null;
    for (const slot of this.#slots.values()) {
      if (slot.conv.sessionId === sessionId) return slot;
    }
    if (exactOnly) return null;
    // Prefix, to match the store's byId: the short id a listing prints must
    // resolve to a live conversation rather than cold-resuming a second child
    // for the same session.
    //
    // UNAMBIGUOUS, for the same reason byId is. Returning the first startsWith
    // hit made `resume 0` silently re-activate whichever conversation happened
    // to be iterated first -- observed live, where it re-activated the ACTIVE
    // one and reported success, so the ambiguity error below could never fire.
    // On more than one hit, fall through: the store sees the same collision and
    // raises the error that tells the caller to type more characters.
    let hit: Slot | null = null;
    for (const slot of this.#slots.values()) {
      if (!slot.conv.sessionId.startsWith(sessionId)) continue;
      if (hit) return null;
      hit = slot;
    }
    return hit;
  }

  /**
   * The picker's list. Live conversations go on top, per the spec, each with a
   * busy flag -- the whole point being that a parked session can be busy.
   */
  list(limit = 50): SessionEntry[] {
    const bySession = new Map<string, Conversation>();
    for (const slot of this.#slots.values()) bySession.set(slot.conv.sessionId, slot.conv);

    const liveRows: SessionEntry[] = [];
    const diskRows: SessionEntry[] = [];

    for (const row of this.#store.list(limit)) {
      const conv = bySession.get(row.id);
      const entry: SessionEntry = {
        id: row.id,
        file: row.file,
        label: row.label,
        at: row.at,
        turns: row.turns,
        live: conv !== undefined,
        busy: conv?.busy ?? false,
      };
      if (conv) {
        bySession.delete(row.id);
        liveRows.push(entry);
      } else {
        diskRows.push(entry);
      }
    }

    // Live conversations with no row yet -- nothing has settled in them.
    for (const [sessionId, conv] of bySession) {
      const slot = this.#slots.get(conv.id);
      liveRows.push({
        id: sessionId,
        file: conv.sessionFile,
        label: conv.label(),
        at: slot?.lastActive ?? this.#clock.now(),
        turns: conv.turnCount(),
        live: true,
        busy: conv.busy,
      });
    }

    liveRows.sort((a, b) => b.at - a.at);
    return [...liveRows, ...diskRows];
  }

  #emitSessions(): void {
    this.#emit({ t: "sessions", entries: this.list(), activeId: this.active?.sessionId ?? "" });
  }

  /* ----------------------------------------------------------- shutdown */

  shutdown(): void {
    for (const slot of this.#slots.values()) {
      this.#clearTimers(slot);
      this.#record(slot.conv, slot.lastActive);
      slot.conv.dispose();
    }
    this.#slots.clear();
    this.#activeId = "";
  }
}
