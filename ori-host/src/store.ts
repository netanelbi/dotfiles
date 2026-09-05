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
    this.#byPrefix = this.db.query(
      `SELECT ${SELECT_COLS} FROM sessions
         WHERE substr(id, 1, $n) = $prefix ORDER BY at DESC LIMIT 1`,
    );
    this.#setOffset = this.db.query(
      `UPDATE sessions SET read_offset = $readOffset WHERE id = $id`,
    );
    this.#upsertMany = this.db.transaction((entries: SessionUpsert[]) => {
      for (const e of entries) this.#run(e);
    });
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

  list(limit = 50): SessionRow[] {
    return this.#list.all({ limit }) as SessionRow[];
  }

  /** Exact id first, then prefix. Returns null when nothing matches. */
  byId(id: string): SessionRow | null {
    const key = String(id ?? "");
    if (key === "") return null;
    const exact = this.#byExactId.get({ id: key }) as SessionRow | null;
    if (exact) return exact;
    return this.#byPrefix.get({ n: key.length, prefix: key }) as SessionRow | null;
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
