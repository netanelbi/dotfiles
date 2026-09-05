import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, renameSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Catalog, defaultCatalogIo, defaultPaths, type CatalogIo, type CatalogPaths } from "../src/catalog";

/* ------------------------------------------------------------------ fixtures */

const PATHS: CatalogPaths = {
  settings: "/cfg/settings.json",
  models: "/cfg/models.json",
  registry: "/cfg/subagents/registry.json",
  choice: "/state/ori-model.json",
  cache: "/state/ori-catalog.json",
};

/** In-memory io: no filesystem, no watcher, timers run immediately. */
function memIo(files: Record<string, string>): CatalogIo & { files: Record<string, string> } {
  return {
    files,
    async readText(p) {
      return files[p] ?? null;
    },
    async writeText(p, t) {
      files[p] = t;
    },
    watchDir() {
      return () => {};
    },
    setTimer(fn) {
      fn();
      return () => {};
    },
  };
}

const MODELS = [
  { provider: "ollama", id: "deepseek-v4", name: "DeepSeek v4" },
  { provider: "ollama", id: "qwen3-coder", name: "Qwen3 Coder" },
  { provider: "anthropic", id: "claude-haiku-4-5", name: "Haiku" },
  { provider: "huggingface", id: "claude-haiku-4-5", name: "Haiku (HF)" },
];

async function loaded(files: Record<string, string>): Promise<Catalog> {
  const c = new Catalog({ paths: PATHS, io: memIo(files) });
  await c.start();
  c.applyModels(MODELS);
  return c;
}

/* ------------------------------------------------------------------- globs */

test("enabledModels matches exactly and on a trailing-* prefix", async () => {
  const c = await loaded({
    [PATHS.settings]: JSON.stringify({ enabledModels: ["ollama/*", "anthropic/claude-haiku-4-5"] }),
  });

  expect(c.modelEnabled("ollama/deepseek-v4")).toBe(true); // glob
  expect(c.modelEnabled("ollama/")).toBe(true); // glob, degenerate but consistent
  expect(c.modelEnabled("anthropic/claude-haiku-4-5")).toBe(true); // exact
  expect(c.modelEnabled("anthropic/claude-opus-4")).toBe(false); // no partial-exact
  expect(c.modelEnabled("huggingface/claude-haiku-4-5")).toBe(false);
});

test("a bare pattern is not treated as a prefix", async () => {
  const c = await loaded({ [PATHS.settings]: JSON.stringify({ enabledModels: ["ollama/deep"] }) });
  expect(c.modelEnabled("ollama/deepseek-v4")).toBe(false);
});

/* ------------------------------------------------------------ usableModels */

test("usableModels is scoped by enabledModels when there are any", async () => {
  const c = await loaded({
    [PATHS.settings]: JSON.stringify({ enabledModels: ["ollama/*"] }),
    [PATHS.models]: JSON.stringify({ providers: { ollama: {}, anthropic: {} } }),
  });
  expect(c.usableModels.map((m) => m.id)).toEqual(["deepseek-v4", "qwen3-coder"]);
});

test("with no enabledModels it falls back to the declared providers", async () => {
  const c = await loaded({
    [PATHS.models]: JSON.stringify({ providers: { anthropic: { apiKey: "x" } } }),
  });
  expect(c.usableModels.map((m) => m.provider)).toEqual(["anthropic"]);
});

test("a filter that matches nothing falls back to the UNFILTERED list", async () => {
  const c = await loaded({
    // Neither file names anything in the catalogue -- the shape moved, or the
    // user pruned it to models that no longer exist.
    [PATHS.settings]: JSON.stringify({ enabledModels: ["mistral/*"] }),
    [PATHS.models]: JSON.stringify({ providers: { mistral: {} } }),
  });
  expect(c.usableModels).toEqual(c.availableModels);
  expect(c.usableModels.length).toBe(4);
});

test("the current model is retained even when the filter excludes it", async () => {
  const c = await loaded({
    [PATHS.settings]: JSON.stringify({ enabledModels: ["ollama/*"] }),
  });
  c.applyModelChoice("anthropic", "claude-haiku-4-5");

  const keys = c.usableModels.map((m) => `${m.provider}/${m.id}`);
  expect(keys).toContain("anthropic/claude-haiku-4-5");
  expect(keys).toContain("ollama/deepseek-v4");
  expect(keys).not.toContain("huggingface/claude-haiku-4-5");
});

/* ------------------------------------------------------------------ levels */

test("minimal and xhigh are never offered", async () => {
  const c = await loaded({});
  // Cold: pi's universal scale, minus what the endpoint refuses.
  expect(c.effortScale()).toEqual(["off", "low", "medium", "high"]);

  c.applyLevels(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
  expect(c.effortScale()).toEqual(["off", "low", "medium", "high", "max"]);
});

test("rejectLevel unpins a level the endpoint refused", async () => {
  const c = await loaded({});
  c.applyLevels(["off", "low", "medium", "high"]);
  c.setEffort("high");
  c.rejectLevel("high");
  expect(c.effort).toBe("");
  expect(c.effortScale()).not.toContain("high");
});

/* -------------------------------------------------------------- registry */

test("only running subagents with an activity line are reported", async () => {
  const c = await loaded({
    [PATHS.registry]: JSON.stringify({
      a: { status: "running", activity: "reading src/catalog.ts" },
      b: { status: "running" }, // no line yet
      c: { status: "done", activity: "finished an hour ago" }, // kept for resume
    }),
  });
  expect(c.agentActivity).toEqual({ a: "reading src/catalog.ts" });
});

/* ----------------------------------------------------------- persistence */

test("an effort change rewrites only the small choice file", async () => {
  const io = memIo({});
  const c = new Catalog({ paths: PATHS, io });
  await c.start();
  c.applyModels(MODELS); // writes the catalogue once
  const cacheAfterModels = io.files[PATHS.cache];

  c.setEffort("medium");
  expect(JSON.parse(io.files[PATHS.choice] ?? "{}").effort).toBe("medium");
  expect(io.files[PATHS.cache]).toBe(cacheAfterModels); // untouched
});

test("the old single-file format is still readable", async () => {
  const c = await loaded({
    [PATHS.choice]: JSON.stringify({
      provider: "ollama",
      modelId: "deepseek-v4",
      effort: "high",
      levels: ["off", "high"],
      levelsFor: "ollama/deepseek-v4",
      models: [{ provider: "ollama", id: "deepseek-v4", name: "DeepSeek v4" }],
    }),
  });
  expect(c.provider).toBe("ollama");
  expect(c.effort).toBe("high");
  expect(c.thinkingLevels).toEqual(["off", "high"]);
});

test("half a choice is not restored", async () => {
  // A provider with no id builds `--provider anthropic --model <stale>`, which
  // pi accepts as a fabricated custom model rather than rejecting.
  const c = await loaded({ [PATHS.choice]: JSON.stringify({ provider: "anthropic" }) });
  expect(c.provider).toBe("");
  expect(c.model).toBe("");
});

/* ----------------------------------------------------------- the debounce
 * Real fs.watch, real timers, real files. The point of the test is the thing
 * the in-memory io cannot show: an editor saves once and inotify fires several
 * times, so a burst of saves must cost ONE read.
 *
 * The burst has to be the pattern that actually MULTIPLIES events. Five plain
 * writeFileSync calls to one path do not: measured, bun's fs.watch coalesces
 * them into a single event, so that version of this test passed with the
 * debounce deleted outright. An editor save is write-temp / rename-into-place /
 * touch, which is two events per save that reach the watched basename -- three
 * saves measured 6 events, i.e. 6 reloads undebounced against 1 with it.
 */

test("a burst of editor-style saves collapses into one reload", async () => {
  const dir = mkdtempSync(join(tmpdir(), "ori-catalog-"));
  try {
    mkdirSync(join(dir, "subagents"));
    const paths: CatalogPaths = {
      settings: join(dir, "settings.json"),
      models: join(dir, "models.json"),
      registry: join(dir, "subagents", "registry.json"),
      choice: join(dir, "ori-model.json"),
      cache: join(dir, "ori-catalog.json"),
    };
    writeFileSync(paths.settings, JSON.stringify({ enabledModels: [] }));

    // Longer than the burst it has to swallow, so "one reload" is a property of
    // the debounce and not of the burst finishing before the first deadline.
    const c = new Catalog({ paths, io: defaultCatalogIo, watchDebounceMs: 150 });
    await c.start();
    const before = c.reloadCount;

    const tmp = join(dir, "settings.json.tmp");
    for (let i = 0; i < 3; i++) {
      writeFileSync(tmp, JSON.stringify({ enabledModels: [`ollama/m${i}*`] }));
      renameSync(tmp, paths.settings);
      const t = new Date();
      utimesSync(paths.settings, t, t);
      await Bun.sleep(20);
    }

    await Bun.sleep(500);
    expect(c.reloadCount - before).toBe(1);
    // ...and the reload actually read the last write, rather than merely not
    // having happened.
    expect(c.enabledModels).toEqual(["ollama/m2*"]);
    await c.stop();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("defaultPaths puts state under XDG_STATE_HOME", () => {
  const p = defaultPaths({ HOME: "/home/x", XDG_STATE_HOME: "/home/x/.local/state" });
  expect(p.settings).toBe("/home/x/.pi/agent/settings.json");
  expect(p.choice).toBe("/home/x/.local/state/ori-host/ori-model.json");
});
