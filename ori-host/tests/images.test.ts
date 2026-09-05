import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Buffer } from "node:buffer";
import {
  capture,
  encode,
  sniffMime,
  ImageStaging,
  MAX_IMAGE_BYTES,
  defaultImageIo,
  type ImageIo,
} from "../src/images";

/* ------------------------------------------------------------------- sniff */

function head(...bytes: number[]): Uint8Array {
  const out = new Uint8Array(32);
  out.set(bytes);
  return out;
}

test("sniffMime recognises the four formats from their magic bytes", () => {
  expect(sniffMime(head(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00))).toBe("image/png");
  expect(sniffMime(head(0xff, 0xd8, 0xff, 0xe0))).toBe("image/jpeg");
  expect(sniffMime(head(0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x00))).toBe("image/gif");
  expect(
    sniffMime(head(0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50, 0)),
  ).toBe("image/webp");
});

test("sniffMime rejects a non-image, including another RIFF container", () => {
  expect(sniffMime(head(0x68, 0x65, 0x6c, 0x6c, 0x6f))).toBe("");
  // WAVE, not WEBP -- checking only the R of RIFF would pass this.
  expect(sniffMime(head(0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x41, 0x56, 0x45, 0))).toBe("");
  expect(sniffMime(new Uint8Array([0x89, 0x50]))).toBe(""); // too short to be sure
});

/* ------------------------------------------------------------------ encode */

const PNG_HEAD = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00];

function fakeIo(files: Record<string, Uint8Array>): ImageIo {
  return {
    async run() {
      return { code: 0, stdout: "" };
    },
    async size(p) {
      return files[p]?.length ?? -1;
    },
    async read(p) {
      return files[p] ?? new Uint8Array();
    },
  };
}

test("encode returns the sniffed mime and standard base64", async () => {
  const bytes = new Uint8Array(64);
  bytes.set(PNG_HEAD);
  const r = await encode("/x.png", fakeIo({ "/x.png": bytes }));
  expect(r.ok).toBe(true);
  if (r.ok) {
    expect(r.mime).toBe("image/png");
    expect(r.bytes).toBe(64);
    expect(r.data).toBe(Buffer.from(bytes).toString("base64"));
  }
});

test("the 12MB cap rejects, with the size in the message", async () => {
  const io: ImageIo = {
    async run() {
      return { code: 0, stdout: "" };
    },
    // A size check that does not read the file -- the point of having `size`
    // separate is that an oversized paste is never loaded into memory.
    async size() {
      return MAX_IMAGE_BYTES + 1;
    },
    async read() {
      throw new Error("must not read a file that is over the cap");
    },
  };
  const r = await encode("/huge.png", io);
  expect(r.ok).toBe(false);
  if (!r.ok) {
    expect(r.error).toContain("too large");
    expect(r.error).toContain("12MB");
  }
});

test("exactly at the cap is accepted", async () => {
  const bytes = new Uint8Array(MAX_IMAGE_BYTES);
  bytes.set(PNG_HEAD);
  const r = await encode("/edge.png", fakeIo({ "/edge.png": bytes }));
  expect(r.ok).toBe(true);
});

test("a missing file, an empty file and a text file are told apart", async () => {
  const io = fakeIo({ "/empty.png": new Uint8Array(0), "/text.png": Buffer.from("hello world") });
  const gone = await encode("/nope.png", io);
  const empty = await encode("/empty.png", io);
  const text = await encode("/text.png", io);
  expect(gone.ok === false && gone.error).toContain("cannot read image");
  expect(empty.ok === false && empty.error).toContain("empty image");
  // wl-paste writes the clipboard TEXT to the file when there is no image on
  // it, so this is a real case and not a hypothetical one.
  expect(text.ok === false && text.error).toContain("not an image");
});

test("a >1MB image encodes in well under 50ms", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ori-img-"));
  try {
    const path = join(dir, "big.png");
    const bytes = new Uint8Array(4 * 1024 * 1024);
    bytes.set(PNG_HEAD);
    // Not all zeroes: a compressible buffer would flatter any encoder.
    for (let i = 16; i < bytes.length; i++) bytes[i] = (i * 2654435761) & 0xff;
    writeFileSync(path, bytes);

    // Warm the page cache so this measures the encoder and not the disk.
    await encode(path, defaultImageIo);

    const t0 = performance.now();
    const r = await encode(path, defaultImageIo);
    const ms = performance.now() - t0;

    expect(r.ok).toBe(true);
    if (r.ok) expect(r.data.length).toBe(Math.ceil(bytes.length / 3) * 4);
    // The QML hand-rolled encoder this replaces took 2170ms for 12MB on the UI
    // thread. Buffer.toString("base64") is ~1.34ms for 8MB.
    expect(ms).toBeLessThan(50);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/* ----------------------------------------------------------------- capture */

test("exit 3 is silent -- an ordinary Ctrl+V of text", async () => {
  const io: ImageIo = { ...fakeIo({}), async run() {
    return { code: 3, stdout: "" };
  } };
  expect(await capture(io)).toEqual({ t: "none" });
});

test("a successful capture hands back the path it wrote", async () => {
  const io: ImageIo = { ...fakeIo({}), async run(argv) {
    // The script is what asks for the offered types first; a capture that did
    // not would happily write clipboard text into a .png.
    expect(argv[0]).toBe("sh");
    expect(argv[2]).toContain("wl-paste --list-types");
    return { code: 0, stdout: "/run/user/1000/ori/paste-1787813158822066810.png\n" };
  } };
  expect(await capture(io)).toEqual({
    t: "image",
    path: "/run/user/1000/ori/paste-1787813158822066810.png",
  });
});

test("any other failure is reported", async () => {
  const io: ImageIo = { ...fakeIo({}), async run() {
    return { code: 4, stdout: "" };
  } };
  expect(await capture(io)).toEqual({
    t: "failed",
    why: "could not read the clipboard image",
  });
});

/* ----------------------------------------------------------------- staging */

test("markers are 1-based and resolve back to paths", () => {
  const s = new ImageStaging();
  expect(s.attach("/a.png")).toBe(1);
  expect(s.attach("/b.png")).toBe(2);
  expect(s.resolve([2, 1])).toEqual(["/b.png", "/a.png"]);
  expect(s.resolve([9])).toEqual([]);
});

test("sync drops an attachment whose [Image n] was deleted from the draft", () => {
  const s = new ImageStaging();
  s.attach("/a.png");
  s.attach("/b.png");

  s.sync("look at [Image 2] please"); // [Image 1] was deleted
  expect(s.list().map((a) => a.path)).toEqual(["/b.png"]);
  expect(s.resolve([1, 2])).toEqual(["/b.png"]);

  s.sync("nothing left");
  expect(s.list()).toEqual([]);
});

test("a marker number is never re-used after its picture is dropped", () => {
  const s = new ImageStaging();
  s.attach("/a.png");
  s.sync(""); // dropped
  expect(s.attach("/b.png")).toBe(2);
  // If the counter restarted, a stale "[Image 1]" left in some other draft
  // would resurrect the wrong picture.
  expect(s.resolve([1])).toEqual([]);
});
