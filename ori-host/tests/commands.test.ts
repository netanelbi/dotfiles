import { test, expect } from "bun:test";
import { parseCommand, panelCommands, type CommandContext } from "../src/commands";

const MODELS = [
  { provider: "ollama", id: "deepseek-v4", name: "DeepSeek v4" },
  { provider: "anthropic", id: "claude-haiku-4-5", name: "Haiku" },
  { provider: "huggingface", id: "claude-haiku-4-5", name: "Haiku (HF)" },
];

function ctx(over: Partial<CommandContext> = {}): CommandContext {
  return {
    warm: false,
    models: MODELS,
    usable: MODELS.slice(0, 1),
    levels: ["off", "low", "medium", "high"],
    ...over,
  };
}

/* --------------------------------------------------------------- all seven */

test("every panel command parses", () => {
  const warm = ctx({ warm: true });
  const kinds = [
    "/model ollama/deepseek-v4",
    "/effort medium",
    "/new",
    "/compact",
    "/name a good name",
    "/export",
    "/restart",
  ].map((line) => {
    const r = parseCommand(line, warm);
    expect(r.t).toBe("intent");
    return r.t === "intent" ? r.intent.t : r.t;
  });

  expect(kinds).toEqual(["set_model", "set_effort", "new", "compact", "name", "export", "restart"]);
});

test("the argument is captured whole, and leading/trailing space is not part of it", () => {
  const r = parseCommand("  /name   two  words  ", ctx({ warm: true }));
  expect(r).toEqual({ t: "intent", intent: { t: "name", name: "two  words" } });
});

test("a line that is not a panel command passes through to the model", () => {
  for (const line of ["/models", "/help", "hello", "/effortless", "not /new"])
    expect(parseCommand(line, ctx()).t).toBe("pass");
});

/* ---------------------------------------------------------------- cold/warm */

test("/model and /effort work with no child running", () => {
  const cold = ctx({ warm: false });
  expect(parseCommand("/model ollama/deepseek-v4", cold)).toEqual({
    t: "intent",
    intent: { t: "set_model", provider: "ollama", id: "deepseek-v4" },
  });
  expect(parseCommand("/effort high", cold)).toEqual({
    t: "intent",
    intent: { t: "set_effort", level: "high" },
  });
});

test("/new and /restart work cold too", () => {
  expect(parseCommand("/new", ctx()).t).toBe("intent");
  expect(parseCommand("/restart", ctx()).t).toBe("intent");
});

test("/compact, /export and /name refuse while cold, and say why", () => {
  for (const line of ["/compact", "/export", "/name x"]) {
    const r = parseCommand(line, ctx({ warm: false }));
    expect(r.t).toBe("error");
    if (r.t === "error") expect(r.message).toContain("nothing running");
  }
});

test("/name with no argument is a usage error, not a warmth error", () => {
  expect(parseCommand("/name", ctx({ warm: true }))).toEqual({
    t: "error",
    message: "/name <new name>",
  });
  expect(parseCommand("/name", ctx({ warm: false }))).toEqual({
    t: "error",
    message: "/name <new name>",
  });
});

/* ------------------------------------------------------------------ /model */

test("a bare id resolves when it is unambiguous", () => {
  expect(parseCommand("/model deepseek-v4", ctx())).toEqual({
    t: "intent",
    intent: { t: "set_model", provider: "ollama", id: "deepseek-v4" },
  });
});

test("an ambiguous bare id is an ERROR, never resolved to one of them", () => {
  const r = parseCommand("/model claude-haiku-4-5", ctx());
  expect(r.t).toBe("error");
  if (r.t === "error") {
    expect(r.message).toContain("2 providers");
    expect(r.message).toContain("name one");
  }
});

test("a fully qualified id beats the ambiguity", () => {
  expect(parseCommand("/model huggingface/claude-haiku-4-5", ctx())).toEqual({
    t: "intent",
    intent: { t: "set_model", provider: "huggingface", id: "claude-haiku-4-5" },
  });
});

test("/model accepts a model the completion does not offer", () => {
  // `usable` is one row; the anthropic model is hidden from completion and is
  // still reachable by typing it out.
  const r = parseCommand("/model anthropic/claude-haiku-4-5", ctx());
  expect(r.t).toBe("intent");
});

test("/model reports an unknown id and an empty catalogue differently", () => {
  const unknown = parseCommand("/model nope", ctx());
  expect(unknown.t).toBe("error");
  if (unknown.t === "error") expect(unknown.message).toContain('no such model "nope"');

  const empty = parseCommand("/model ollama/deepseek-v4", ctx({ models: [] }));
  expect(empty.t).toBe("error");
  if (empty.t === "error") expect(empty.message).toContain("no model list yet");
});

test("/model bare prints usage", () => {
  expect(parseCommand("/model", ctx())).toEqual({
    t: "error",
    message: "/model <provider>/<id>",
  });
});

/* ----------------------------------------------------------------- /effort */

test("a level outside the scale is refused with the scale", () => {
  // pi acks set_thinking_level success:true for EVERY string and clamps
  // silently, so nothing downstream would ever report this.
  for (const line of ["/effort", "/effort minimal", "/effort banana"]) {
    const r = parseCommand(line, ctx());
    expect(r.t).toBe("error");
    if (r.t === "error") expect(r.message).toBe("/effort off | low | medium | high");
  }
});

/* -------------------------------------------------------------- completion */

test("panelCommands carries live descriptions and closed value sets", () => {
  const rows = panelCommands({ usable: MODELS, levels: ["off", "high"] });
  expect(rows.map((r) => r.name)).toEqual([
    "model",
    "effort",
    "new",
    "compact",
    "name",
    "export",
    "restart",
  ]);
  expect(rows.every((r) => r.source === "panel")).toBe(true);
  expect(rows[0]?.description).toContain("3 usable");
  expect(rows[0]?.values).toContain("huggingface/claude-haiku-4-5");
  expect(rows[1]?.values).toEqual(["off", "high"]);
  expect(rows[2]?.values).toBeUndefined();
});
