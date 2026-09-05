/**
 * Clipboard capture, mime sniffing, base64, and the staged-attachment list.
 *
 * The image is written to a FILE and the path is what gets attached, rather
 * than being carried around as base64. Two reasons: the panel renders a path,
 * and a path is something the model can be handed to a tool later, which a blob
 * in a text field never can be. The base64 exists for exactly as long as the
 * frame that carries it to pi.
 *
 * ------------------------------------------------------------------- base64
 * `Buffer.from(bytes).toString("base64")`. MEASURED at 1.34 ms for 8 MB.
 * The QML this replaces hand-rolled the encoder because Qt.btoa takes a QString
 * and would have UTF-8'd every byte above 0x7F into two -- correct reasoning,
 * ruinous result: 2170 ms for 12 MB, on the UI thread, freezing the desktop for
 * two seconds per paste. Do not hand-roll it here, do not use `Bun.base64` (it
 * does not exist), and do not use `.toBase64()` (slower).
 */

import { Buffer } from "node:buffer";

/** pi's own attachment ceiling. Above this the request is refused by the API,
 *  so refusing here with a readable message is strictly better. */
export const MAX_IMAGE_BYTES = 12 * 1024 * 1024;

/**
 * Ask for the OFFERED TYPES first. `wl-paste` with no image on the clipboard
 * happily writes the TEXT to the file, and a text file named .png only fails
 * later, at sniffMime, with a message about a corrupt image.
 *
 * Exit 3 is "nothing image-shaped on the clipboard" -- an ordinary Ctrl+V of
 * text -- and must stay SILENT: the composer pastes the text itself.
 */
const CAPTURE_SCRIPT =
  "t=$(wl-paste --list-types 2>/dev/null | grep -m1 '^image/'); " +
  '[ -n "$t" ] || exit 3; ' +
  'd="${XDG_RUNTIME_DIR:-/tmp}/ori"; mkdir -p "$d" || exit 4; ' +
  'f="$d/paste-$(date +%s%N).${t#image/}"; ' +
  'wl-paste --type "$t" > "$f" 2>/dev/null && [ -s "$f" ] && printf %s "$f"';

export const NO_IMAGE_EXIT = 3;

export interface ImageIo {
  run(argv: string[]): Promise<{ code: number; stdout: string }>;
  /** Byte length, or -1 when the file is not there. Separate from `read` so a
   *  100 MB paste is rejected without being loaded into memory first. */
  size(path: string): Promise<number>;
  read(path: string): Promise<Uint8Array>;
}

export const defaultImageIo: ImageIo = {
  async run(argv) {
    const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "ignore" });
    const stdout = await new Response(proc.stdout).text();
    const code = await proc.exited;
    return { code, stdout };
  },
  async size(path) {
    const f = Bun.file(path);
    return (await f.exists()) ? f.size : -1;
  },
  async read(path) {
    return await Bun.file(path).bytes();
  },
};

export type CaptureResult =
  | { t: "image"; path: string }
  /** Exit 3. Not an error, not reported anywhere. */
  | { t: "none" }
  | { t: "failed"; why: string };

export async function capture(io: ImageIo = defaultImageIo): Promise<CaptureResult> {
  const { code, stdout } = await io.run(["sh", "-c", CAPTURE_SCRIPT]);
  if (code === NO_IMAGE_EXIT) return { t: "none" };
  const path = stdout.trim();
  if (code !== 0 || path === "") return { t: "failed", why: "could not read the clipboard image" };
  return { t: "image", path };
}

/**
 * From the MAGIC BYTES, not from the extension: a screenshot tool's output is
 * whatever the tool felt like naming it, and pi keys its image handling on the
 * declared mime.
 */
export function sniffMime(b: Uint8Array): string {
  if (b.length > 8 && b[0] === 0x89 && b[1] === 0x50) return "image/png";
  if (b.length > 3 && b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b.length > 6 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif";
  // RIFF....WEBP -- the size field sits between the two tags, so both have to
  // be checked or any RIFF container (wav included) passes as an image.
  if (
    b.length > 12 &&
    b[0] === 0x52 &&
    b[1] === 0x49 &&
    b[2] === 0x46 &&
    b[3] === 0x46 &&
    b[8] === 0x57 &&
    b[9] === 0x45 &&
    b[10] === 0x42 &&
    b[11] === 0x50
  )
    return "image/webp";
  return "";
}

export type Encoded =
  | { ok: true; mime: string; data: string; bytes: number }
  | { ok: false; error: string };

export async function encode(path: string, io: ImageIo = defaultImageIo): Promise<Encoded> {
  const size = await io.size(path);
  if (size < 0) return { ok: false, error: `cannot read image: ${path}` };
  if (size === 0) return { ok: false, error: `empty image: ${path}` };
  if (size > MAX_IMAGE_BYTES)
    return {
      ok: false,
      error: `image too large (${Math.round(size / 1048576)}MB, limit ${MAX_IMAGE_BYTES / 1048576}MB): ${path}`,
    };

  const bytes = await io.read(path);
  const mime = sniffMime(bytes);
  if (mime === "") return { ok: false, error: `not an image: ${path}` };
  return {
    ok: true,
    mime,
    bytes: bytes.length,
    data: Buffer.from(bytes).toString("base64"),
  };
}

export interface Attachment {
  /** 1-based, and it is the number in the `[Image n]` marker. */
  n: number;
  path: string;
}

/**
 * Staged pastes, addressed by the marker the composer inserts.
 *
 * The marker is Claude Code's, deliberately: `[Image 1]` stands in for the
 * picture so the composer stays a plain text field, and the number is how the
 * two halves stay matched when you delete one of them.
 */
export class ImageStaging {
  #items: Attachment[] = [];
  #seq = 0;

  /** The index keeps counting up across the whole panel session, so a deleted
   *  `[Image 1]` is never re-used by the next paste and cannot resurrect the
   *  wrong picture. */
  attach(path: string): number {
    const n = ++this.#seq;
    this.#items.push({ n, path });
    return n;
  }

  /** Drop anything whose marker the user has deleted from the draft. Called on
   *  composer edits, so the strip under the field matches what will be sent. */
  sync(draft: string): void {
    this.#items = this.#items.filter((a) => draft.includes(marker(a.n)));
  }

  /** Marker numbers -> paths, in the order the numbers were given. Unknown
   *  numbers are skipped rather than throwing: the panel and the host can be
   *  one edit out of step, and a missing picture beats a refused question. */
  resolve(ns: readonly number[]): string[] {
    const byN = new Map(this.#items.map((a) => [a.n, a.path] as const));
    const out: string[] = [];
    for (const n of ns) {
      const p = byN.get(n);
      if (p !== undefined) out.push(p);
    }
    return out;
  }

  list(): readonly Attachment[] {
    return this.#items;
  }

  /** Called when the question was ACCEPTED, never merely when one was typed.
   *  Clearing on any attempt threw the picture away behind an `[Image 1]` that
   *  was still sitting in a draft the composer had kept, and the retry then
   *  quietly sent no picture at all. */
  clear(): void {
    this.#items = [];
  }
}

function marker(n: number): string {
  return `[Image ${n}]`;
}
