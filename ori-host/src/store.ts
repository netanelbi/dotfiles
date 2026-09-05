/**
 * The durable session index, plus transcript reading.
 *
 * Replaces two things that were the same job done twice:
 *
 *  - `ori-sessions.json` (PiSession.qml:1610-1767), a JSON blob the panel
 *    re-stringified IN FULL once per settled turn. Here it is a sqlite table in
 *    WAL mode, so a settle is one prepared UPDATE.
 *  - the restore read (PiSession.qml:1691-1703), which did `split("\n")` on a
 *    ~9 MB transcript and then kept only the last 120 entries. **The 120 cap
 *    does not exist here.** The whole transcript is returned, read by streaming,
 *    and a stored byte offset lets a re-read start where the last one stopped.
 *
 * pi writes sessions as JSONL at
 *   ~/.pi/agent/sessions/--<cwd with / as ->--/<ts>_<uuid>.jsonl
 * (docs/session-format.md). Entries are parsed here as `unknown` and narrowed by
 * runtime guards rather than being typed: pi's own declarations are the only
 * legitimate source for those shapes, and this file must not grow a rival copy.
 */

import { Database } from "bun:sqlite";
import { stat } from "node:fs/promises";
import { join } from "node:path";

import { expandTilde } from "./pi/argv";
import type { SessionEntry } from "./protocol";

/** One row of the index. `SessionEntry` minus the two fields only the pool
 *  knows (`live`, `busy`), plus the transcript read cursor. */
export interface SessionRow extends Omit<SessionEntry, "live" | "busy"> {
  /** Byte offset into `file` that has already been read into memory. */
  readOffset: number;
}

/** What `upsert` accepts. `readOffset` is optional because the common caller --
 *  a settled turn -- has nothing to say about the read cursor and must not
 *  clobber it. */
export type SessionUpsert = Omit<SessionRow, "readOffset"> & { readOffset?: number };

/**
 * The slice of the store the pool depends on. Declared here so pool.ts can be
 * tested against a fake without a database, and so `Store` structurally
 * satisfies it without an `implements` clause.
 */
export interface SessionIndex {
  upsert(entry: SessionUpsert): void;
  list(limit?: number): SessionRow[];
  byId(id: string): SessionRow | null;
  /** True when `id` is a prefix of several sessions, so byId() refused it. */
  ambiguous(id: string): boolean;
}

const SELECT_COLS = `id, file, label, at, turns, read_offset AS readOffset`;

export class Store {
  readonly db: Database;

  #upsert;
  #list;
  #byExactId;
  #byPrefix;
  #setOffset;
  #upsertMany;
  #seed;
  #seedMany;
  #getMeta;
  #setMeta;

  constructor(path = ":memory:") {
    // strict:true lets prepared statements take plain `{ id }` objects instead
    // of `{ $id }`, and throws on a missing binding rather than silently
    // binding NULL.
    this.db = new Database(path, { create: true, strict: true });
    // WAL: a reader (the picker) must never block on the writer (a settling
    // turn). This is the whole reason the JSON blob had to go.
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id          TEXT PRIMARY KEY,
        file        TEXT NOT NULL,
        label       TEXT NOT NULL,
        at          INTEGER NOT NULL,
        turns       INTEGER NOT NULL,
        read_offset INTEGER NOT NULL DEFAULT 0
      )`);
    // The only query shape that is not a primary-key hit.
    this.db.exec("CREATE INDEX IF NOT EXISTS sessions_at ON sessions (at DESC)");
    // One-shot facts about the index itself, e.g. "the ori-sessions.json
    // migration has already run". A table rather than a sentinel file: it has to
    // be atomic with the rows it describes, and it is free to live beside them.
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )`);

    this.#upsert = this.db.query(`
      INSERT INTO sessions (id, file, label, at, turns, read_offset)
      VALUES ($id, $file, $label, $at, $turns, COALESCE($readOffset, 0))
      ON CONFLICT(id) DO UPDATE SET
        file  = excluded.file,
        label = excluded.label,
        at    = excluded.at,
        turns = excluded.turns,
        -- NULL means "the caller had nothing to say about the cursor".
        read_offset = COALESCE($readOffset, sessions.read_offset)`);

    this.#list = this.db.query(
      `SELECT ${SELECT_COLS} FROM sessions ORDER BY at DESC LIMIT $limit`,
    );
    this.#byExactId = this.db.query(`SELECT ${SELECT_COLS} FROM sessions WHERE id = $id`);
    // Prefix match, newest first: the old sessionById() accepted "any
    // unambiguous prefix" so a script could pass the short id the listing
    // prints, and the IPC surface still depends on that.
    //
    // LIMIT 2, not 1, and the word UNAMBIGUOUS is load-bearing. Before disk
    // discovery the index held only sessions Ori had created; now it holds
    // every pi session in the workdir -- 207 of them here -- so a colliding
    // 8-char prefix went from rare to ordinary. With LIMIT 1 the collision is
    // invisible and `ipc call ori resume <short>` silently opens the WRONG
    // conversation. Two rows back means "refuse and say so".
    this.#byPrefix = this.db.query(
      `SELECT ${SELECT_COLS} FROM sessions
         WHERE substr(id, 1, $n) = $prefix ORDER BY at DESC LIMIT 2`,
    );
    this.#setOffset = this.db.query(
      `UPDATE sessions SET read_offset = $readOffset WHERE id = $id`,
    );
    this.#upsertMany = this.db.transaction((entries: SessionUpsert[]) => {
      for (const e of entries) this.#run(e);
    });

    // Discovery's write. Deliberately NOT the same statement as #upsert: a
    // scanned row is a guess made from a filename and the first 64 KB of a file,
    // and it must never overwrite a row written by a settled turn or migrated
    // from the old index, both of which know things the scan cannot. So every
    // column here either fills a gap or takes the better of the two values.
    this.#seed = this.db.query(`
      INSERT INTO sessions (id, file, label, at, turns, read_offset)
      VALUES ($id, $file, $label, $at, $turns, 0)
      ON CONFLICT(id) DO UPDATE SET
        -- The path is the one place the file system is authoritative: a session
        -- moved on disk has to be findable at where it is now.
        file  = excluded.file,
        at    = MAX(sessions.at, excluded.at),
        label = CASE WHEN sessions.label = '' THEN excluded.label ELSE sessions.label END,
        -- THE reason this statement exists. A scan reports turns = 0 because
        -- counting them means reading the whole file; a plain upsert would
        -- replace a migrated 972 with that 0.
        turns = MAX(sessions.turns, excluded.turns)`);
    this.#seedMany = this.db.transaction((entries: SessionUpsert[]) => {
      for (const e of entries) {
        this.#seed.run({ id: e.id, file: e.file, label: e.label, at: e.at, turns: e.turns });
      }
    });

    this.#getMeta = this.db.query(`SELECT value FROM meta WHERE key = $key`);
    this.#setMeta = this.db.query(`
      INSERT INTO meta (key, value) VALUES ($key, $value)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value`);
  }

  #run(e: SessionUpsert): void {
    this.#upsert.run({
      id: e.id,
      file: e.file,
      label: e.label,
      at: e.at,
      turns: e.turns,
      readOffset: e.readOffset ?? null,
    });
  }

  upsert(entry: SessionUpsert): void {
    this.#run(entry);
  }

  /** One transaction, one fsync, for a batch (e.g. a startup rescan). */
  upsertMany(entries: SessionUpsert[]): void {
    this.#upsertMany(entries);
  }

  /**
   * Add rows the index does not have, and fill gaps in the ones it does --
   * never overwrite. This is how BOTH discovery paths write: the disk scan and
   * the one-time ori-sessions.json migration. Whichever runs second cannot
   * damage the first, which is what makes their order not matter.
   */
  seed(entries: SessionUpsert[]): void {
    this.#seedMany(entries);
  }

  /** Null when the key was never set. */
  meta(key: string): string | null {
    const row = this.#getMeta.get({ key }) as { value: string } | null;
    return row?.value ?? null;
  }

  setMeta(key: string, value: string): void {
    this.#setMeta.run({ key, value });
  }

  /**
   * Newest first. The default was 50, which was fine while the index held only
   * sessions Ori had created; disk discovery raised the real count to 207 in
   * this workdir, so 50 silently hid most of the user's history behind a cap
   * nothing surfaced. 250 covers reality with headroom, and the payload is
   * ~150 bytes a row -- a rounding error next to one transcript.
   *
   * Open question, deliberately not decided here: discovery lists EVERY pi
   * session in the workdir, not just Ori's, so plain `pi` runs from the same
   * directory now share the picker. Ranking Ori-opened rows first needs a
   * column and a policy; capping is not the place to smuggle one in.
   */
  list(limit = 250): SessionRow[] {
    return this.#list.all({ limit }) as SessionRow[];
  }

  /**
   * Exact id first, then UNAMBIGUOUS prefix. Returns null when nothing matches
   * AND when more than one row shares the prefix -- see `ambiguous()` to tell
   * those two cases apart, because the caller must word them differently.
   */
  byId(id: string): SessionRow | null {
    const key = String(id ?? "");
    if (key === "") return null;
    const exact = this.#byExactId.get({ id: key }) as SessionRow | null;
    if (exact) return exact;
    const hits = this.#byPrefix.all({ n: key.length, prefix: key }) as SessionRow[];
    return hits.length === 1 ? hits[0]! : null;
  }

  /** True when `id` is a prefix of several sessions, so byId() refused it. */
  ambiguous(id: string): boolean {
    const key = String(id ?? "");
    if (key === "") return false;
    if (this.#byExactId.get({ id: key })) return false;
    return (this.#byPrefix.all({ n: key.length, prefix: key }) as SessionRow[]).length > 1;
  }

  setOffset(id: string, readOffset: number): void {
    this.#setOffset.run({ id, readOffset });
  }

  close(): void {
    this.db.close();
  }
}

/* ------------------------------------------------------------------ *
 * Label derivation
 * ------------------------------------------------------------------ */

/** Cap from PiSession.sessionLabel(). Kept exactly: the picker's column was
 *  sized for it. */
export const LABEL_MAX = 90;

/**
 * How a conversation is named: its opening question, whitespace collapsed.
 * Nothing asks pi for a title -- that would be a whole extra turn to name
 * something the first line already names.
 */
export function deriveLabel(text: string): string {
  const t = String(text ?? "").replace(/\s+/g, " ").trim();
  return t.length > LABEL_MAX ? t.slice(0, LABEL_MAX) + "…" : t;
}

/* ------------------------------------------------------------------ *
 * Transcript reading -- streaming, no cap
 * ------------------------------------------------------------------ */

export interface TranscriptRead {
  /** Every entry from `from` to the end of the file. No cap. Parsed but not
   *  typed -- narrowing them is conversation.ts's job, against pi's own types. */
  entries: unknown[];
  /** Byte offset to pass as `from` on the next read. Always lands on a line
   *  boundary, which is also why slicing there can never cut a UTF-8
   *  codepoint in half. */
  offset: number;
  /** Lines that would not parse. A torn final line is normal -- pi appends to
   *  this file and may have been mid-write -- so they are counted, not thrown. */
  torn: number;
}

/**
 * Read a pi session JSONL by STREAMING.
 *
 * `Bun.file().lines()` does NOT exist on Bun 1.4.0 (verified) -- this is
 * `stream()` + `TextDecoderStream` with the split done here. `file.slice(from)`
 * seeks, so re-reading a 9 MB transcript after two new lines costs two lines.
 */
export async function readTranscript(path: string, from = 0): Promise<TranscriptRead> {
  const whole = Bun.file(path);
  const part = from > 0 ? whole.slice(from) : whole;

  const entries: unknown[] = [];
  let torn = 0;
  let offset = from;
  let rest = "";

  const push = (line: string): void => {
    if (line === "") return;
    try {
      entries.push(JSON.parse(line));
    } catch {
      torn++;
    }
  };

  const stream = part.stream().pipeThrough(new TextDecoderStream());
  for await (const chunk of stream) {
    const parts = (rest + chunk).split("\n");
    rest = parts.pop() ?? "";
    for (const line of parts) {
      // +1 for the "\n" that terminated it. Byte length, not string length:
      // the offset is a file position and the file is UTF-8.
      offset += Buffer.byteLength(line, "utf8") + 1;
      push(line);
    }
  }

  // A trailing line with no newline is either a complete last record or a
  // half-written one. Only advance the cursor past it if it parses; otherwise
  // leave the cursor before it so the next read picks it up whole.
  if (rest !== "") {
    const before = entries.length;
    push(rest);
    if (entries.length > before) offset += Buffer.byteLength(rest, "utf8");
  }

  return { entries, offset, torn };
}

/* ------------------------------------------------------------------ *
 * Deriving an index row from a transcript
 * ------------------------------------------------------------------ */

/**
 * Pull the text out of a pi user message entry, or null if this entry is not
 * one. Guards rather than types: the authoritative shapes live in pi's
 * `dist/core/session-manager.d.ts` and must not be duplicated here.
 *
 * Shape being guarded (session-format.md):
 *   {"type":"message","message":{"role":"user","content": string | [{type:"text",text}]}}
 */
function userText(entry: unknown): string | null {
  if (typeof entry !== "object" || entry === null) return null;
  const e = entry as Record<string, unknown>;
  if (e["type"] !== "message") return null;
  const msg = e["message"];
  if (typeof msg !== "object" || msg === null) return null;
  const m = msg as Record<string, unknown>;
  if (m["role"] !== "user") return null;

  const content = m["content"];
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  let out = "";
  for (const block of content) {
    if (typeof block !== "object" || block === null) continue;
    const b = block as Record<string, unknown>;
    if (b["type"] === "text" && typeof b["text"] === "string") out += b["text"];
  }
  return out;
}

/** Label and turn count for an index row. `turns` counts user messages, i.e.
 *  exchanges -- pi records one tool loop as several assistant entries, so
 *  counting assistant entries would count a single answer many times. */
export function summarise(entries: unknown[]): { label: string; turns: number } {
  let label = "";
  let turns = 0;
  for (const entry of entries) {
    const t = userText(entry);
    if (t === null) continue;
    turns++;
    if (label === "") label = deriveLabel(t);
  }
  return { label, turns };
}

/* ------------------------------------------------------------------ *
 * Discovery -- sessions pi wrote that this index has never seen
 * ------------------------------------------------------------------ */

/**
 * pi's own cwd -> directory-name encoding, from `getDefaultSessionDirPath` in
 * `dist/core/session-manager.js`:
 *
 *   `--${resolvedCwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`
 *
 * Transcribed rather than imported because pi does not export it, and it is a
 * FILENAME convention rather than a frame shape -- the rule against
 * hand-declaring pi types is about the wire protocol, which this is not.
 * `/home/netanel/.dotfiles` -> `--home-netanel-.dotfiles--`, verified against
 * the real directory.
 */
export function encodeCwd(cwd: string): string {
  return `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
}

export interface SessionDirOptions {
  /** The directory the pi child runs in -- `buildWorkdir()`, already expanded. */
  workdir: string;
  home: string;
  /** `PI_CODING_AGENT_SESSION_DIR`, if the environment sets it. */
  env?: string;
}

/**
 * Where pi keeps this workdir's transcripts.
 *
 * `PI_CODING_AGENT_SESSION_DIR` names the session directory ITSELF, not its
 * parent (main.js: it is passed straight to `SessionManager` as `sessionDir`),
 * so when it is set there is no cwd encoding to do at all.
 */
export function piSessionDir(o: SessionDirOptions): string {
  if (o.env) return expandTilde(o.env, o.home);
  return join(o.home, ".pi", "agent", "sessions", encodeCwd(o.workdir));
}

/**
 * How much of a session file the label is allowed to cost.
 *
 * The largest real transcript here is 9.9 MB and its first user message ends
 * 640 bytes in -- a session's opening question is by construction within the
 * first few records, after the `session` / `model_change` /
 * `thinking_level_change` header. 64 KB is ~100x that headroom and 0.6% of the
 * big file.
 */
export const HEAD_BYTES = 64 * 1024;

/** One session found on disk. `turns` is always 0 -- see `scanSessions`. */
export interface Discovered {
  id: string;
  file: string;
  label: string;
  /** File mtime in ms, i.e. when the conversation last had anything written. */
  at: number;
  turns: number;
}

/** Enough to tell "this file has not changed" without opening it. */
export interface FileStamp {
  /** `stat.mtimeMs` at FULL precision -- fractional, because Linux keeps
   *  nanoseconds and pi can append twice inside one millisecond. Rounding it
   *  here would make a same-size rewrite in that window invisible. */
  mtime: number;
  size: number;
}

export interface ScanResult {
  /** New or changed sessions only. An unchanged file yields nothing. */
  found: Discovered[];
  /** A stamp for EVERY file seen, keyed by path. Hand it back as `seen` on the
   *  next scan; that is what makes a re-scan cost one stat per file. */
  stamps: Map<string, FileStamp>;
  /** How many files were opened. The point of `seen` is to keep this at 0. */
  read: number;
}

/**
 * pi names a session `<timestamp>_<uuid>.jsonl`. The uuid is the session id the
 * index is keyed on and the only thing `pi --session-id` accepts.
 *
 * A name with no `_` is not a shape pi writes, but it is a shape a human
 * copying a file into the directory produces, so it degrades to "the whole base
 * name is the id" rather than being dropped.
 */
function parseName(name: string): { id: string; stamp: string } {
  const base = name.endsWith(".jsonl") ? name.slice(0, -".jsonl".length) : name;
  const cut = base.lastIndexOf("_");
  if (cut < 0) return { id: base, stamp: "" };
  return { id: base.slice(cut + 1), stamp: base.slice(0, cut) };
}

/**
 * The label for a session, read from the HEAD of the file only.
 *
 * This is the whole performance story of discovery: 40 sessions totalling well
 * over 100 MB, and the old code's answer was to parse every one of them. A
 * `BunFile.slice()` is a seek, so the bytes that reach this process are bounded
 * by `headBytes` no matter how large the file is.
 *
 * Returns "" when the head holds no user message -- either the session has none
 * (opened and abandoned) or its first one is a multi-megabyte image paste that
 * does not fit. Both are indistinguishable from here without the full read this
 * function exists to avoid, so the caller supplies the fallback.
 */
export async function headLabel(path: string, headBytes = HEAD_BYTES): Promise<string> {
  const text = await Bun.file(path).slice(0, headBytes).text();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      // Either a torn record or -- far more likely -- the last line of the
      // window, cut mid-record by the slice. Not an error, just not readable.
      continue;
    }
    const t = userText(entry);
    if (t !== null && t.trim() !== "") return deriveLabel(t);
  }
  return "";
}

/**
 * Every session pi has written for a workdir.
 *
 * `turns` is reported as **0**, always, and that is a decision rather than an
 * omission: the count is the number of user messages, which cannot be known
 * without reading the whole file, and this function exists precisely to not do
 * that. `Store.seed` treats 0 as "no opinion" and keeps whatever the index
 * already holds, so a migrated 972 survives a scan and an honest 0 is shown
 * until the session is opened once and settles a turn.
 *
 * A missing directory is not an error: it means pi has never run in this
 * workdir, which on a fresh machine is the normal case.
 */
export async function scanSessions(
  dir: string,
  seen: ReadonlyMap<string, FileStamp> = new Map(),
  headBytes = HEAD_BYTES,
): Promise<ScanResult> {
  const stamps = new Map<string, FileStamp>();
  const found: Discovered[] = [];
  let read = 0;

  const names: string[] = [];
  try {
    for await (const name of new Bun.Glob("*.jsonl").scan({ cwd: dir, onlyFiles: true })) {
      names.push(name);
    }
  } catch {
    return { found, stamps, read };
  }

  for (const name of names) {
    const file = join(dir, name);
    let stamp: FileStamp;
    try {
      const st = await stat(file);
      stamp = { mtime: st.mtimeMs, size: st.size };
    } catch {
      // Raced with a delete between the glob and the stat.
      continue;
    }
    stamps.set(file, stamp);

    const before = seen.get(file);
    if (before && before.mtime === stamp.mtime && before.size === stamp.size) continue;

    const { id, stamp: written } = parseName(name);
    if (id === "") continue;
    read++;
    // Falls back to the timestamp pi put in the filename: an unlabelled row is
    // still a row the user can pick, and a session that exists but cannot be
    // seen is the bug this whole file is here to fix.
    let label: string;
    try {
      label = (await headLabel(file, headBytes)) || written || id;
    } catch {
      // Unopenable (EACCES, or deleted between the stat and the read). One bad
      // file must cost one row, not the directory: letting this out abandons
      // the scan, and since the caller then never stores the new stamps, every
      // later rescan repeats the failure and the picker stays empty forever.
      // Drop its stamp too, so a file that becomes readable again -- a chmod
      // changes neither mtime nor size -- is retried on the next scan.
      stamps.delete(file);
      continue;
    }
    // Whole ms on the way out: `at` is epoch-ms on the wire (protocol.ts), and
    // the sub-ms part only ever mattered to the change check above.
    found.push({ id, file, label, at: Math.round(stamp.mtime), turns: 0 });
  }

  return { found, stamps, read };
}

/* ------------------------------------------------------------------ *
 * Migrating the index the QML panel kept
 * ------------------------------------------------------------------ */

/**
 * `~/.local/state/quickshell/ori-sessions.json` (PiSession.qml:1610-1767):
 * `{"version":1,"sessions":[{id,file,label,at,count}]}`.
 *
 * Strictly better data than a scan produces -- real labels and real turn counts
 * for up to 40 sessions -- so it is read once and seeded, and `Store.seed`
 * then protects it from being flattened by the scan.
 *
 * Returns null when the file does not exist, which is how the caller knows not
 * to record the migration as done: the old panel may still be running and about
 * to write it.
 */
export async function readLegacyIndex(path: string): Promise<SessionUpsert[] | null> {
  const f = Bun.file(path);
  if (!(await f.exists())) return null;

  let doc: unknown;
  try {
    doc = await f.json();
  } catch {
    // Unreadable is still "seen": nothing is coming from it.
    return [];
  }
  if (typeof doc !== "object" || doc === null) return [];
  const list = (doc as Record<string, unknown>)["sessions"];
  if (!Array.isArray(list)) return [];

  const rows: SessionUpsert[] = [];
  for (const item of list) {
    if (typeof item !== "object" || item === null) continue;
    const r = item as Record<string, unknown>;
    const id = r["id"];
    const file = r["file"];
    if (typeof id !== "string" || id === "" || typeof file !== "string" || file === "") continue;
    rows.push({
      id,
      file,
      label: typeof r["label"] === "string" ? r["label"] : "",
      at: typeof r["at"] === "number" ? r["at"] : 0,
      // `count` was the old name for the same quantity `turns` holds.
      turns: typeof r["count"] === "number" ? r["count"] : 0,
    });
  }
  return rows;
}
