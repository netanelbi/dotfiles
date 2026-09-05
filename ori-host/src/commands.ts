/**
 * The panel-owned slash commands: /model /effort /new /compact /name /export
 * /restart. These never reach the model.
 *
 * PURE DISPATCH. This module parses a composer line and returns an intent or an
 * error message; it opens no file, spawns nothing and sends nothing. The caller
 * executes the intent, which is what makes every rule below testable without a
 * child.
 *
 * The whole reason /model and /effort live here rather than being forwarded to
 * pi is that they MUST work with no child running -- "cold". Someone types
 * `/model ...` before ever asking a question, and the answer has to be the next
 * spawn's `--provider/--model`, not a refusal.
 */

import type { ModelChoice, SlashCommand } from "./protocol";

/**
 * From PiSession.qml:2458, kept verbatim. `[\s\S]` rather than `.` so a
 * multi-line `/name` argument is captured whole, and the optional group means
 * `/model` bare is a match (and gets its own usage message) while `/models` is
 * not a panel command at all and goes to pi as a prompt.
 */
export const PANEL_COMMAND_RE =
  /^\/(model|effort|new|compact|export|name|restart)(?:\s+([\s\S]*))?$/;

export type Intent =
  /** Cold: the caller applies this locally and it reaches pi as the next
   *  spawn's argv. Warm: the caller sends set_model and moves state only when
   *  pi says it moved. */
  | { t: "set_model"; provider: string; id: string }
  | { t: "set_effort"; level: string }
  | { t: "new" }
  | { t: "compact" }
  | { t: "name"; name: string }
  | { t: "export" }
  | { t: "restart" };

export type CommandOutcome =
  /** Not a panel command. The line is an ordinary question. */
  | { t: "pass" }
  | { t: "intent"; intent: Intent }
  /** A panel command that was rejected. It must land on the error strip and
   *  NOT in the conversation -- a bad `/model nope` sent to the model is the
   *  bug this return value exists to prevent. */
  | { t: "error"; message: string };

export interface CommandContext {
  /** A pi child is up and has answered. /compact, /name and /export need one. */
  warm: boolean;
  /** The FULL catalogue. /model accepts more than it offers -- see below. */
  models: readonly ModelChoice[];
  /** What /model offers, for the completion list only. */
  usable: readonly ModelChoice[];
  /** Catalog.effortScale(). */
  levels: readonly string[];
}

export function parseCommand(line: string, ctx: CommandContext): CommandOutcome {
  const m = PANEL_COMMAND_RE.exec(line.trim());
  if (!m) return { t: "pass" };

  const name = m[1] ?? "";
  const arg = (m[2] ?? "").trim();

  switch (name) {
    case "model":
      return chooseModel(arg, ctx);
    case "effort":
      return setEffort(arg, ctx);
    case "new":
      return { t: "intent", intent: { t: "new" } };
    case "restart":
      return { t: "intent", intent: { t: "restart" } };
    case "compact":
      // A cold child has no context to shrink, and the next question spawns one
      // that starts small anyway.
      return ctx.warm ? { t: "intent", intent: { t: "compact" } } : cold("/compact");
    case "export":
      // There IS a session file on disk when cold, but it belongs to a
      // conversation the picker owns rather than to a bare prompt.
      return ctx.warm ? { t: "intent", intent: { t: "export" } } : cold("/export");
    case "name":
      // Usage before warmth: told you typed it wrong is more useful than told
      // it would not have worked anyway.
      if (arg === "") return { t: "error", message: "/name <new name>" };
      return ctx.warm ? { t: "intent", intent: { t: "name", name: arg } } : cold("/name");
    default:
      return { t: "pass" };
  }
}

function cold(cmd: string): CommandOutcome {
  return { t: "error", message: `${cmd}: nothing running -- ask Ori something first` };
}

/**
 * Accepts "provider/id" -- what the completion writes and what set_model needs
 * -- and a bare id, because a bare id is what the footer shows and making
 * someone retype a prefix the panel never displayed is a trap.
 *
 * Validated against the FULL list, not the usable one: completion must not
 * offer a dead provider, but naming one in full by hand is a deliberate act.
 */
function chooseModel(spec: string, ctx: CommandContext): CommandOutcome {
  if (ctx.models.length === 0)
    return { t: "error", message: "/model: no model list yet -- ask Ori something once first" };
  if (spec === "") return { t: "error", message: "/model <provider>/<id>" };

  const exact = ctx.models.find((m) => `${m.provider}/${m.id}` === spec);
  const bare = ctx.models.filter((m) => m.id === spec);
  const hit = exact ?? (bare.length === 1 ? bare[0] : undefined);

  if (!hit) {
    // Ambiguity is REPORTED, never resolved by picking the first. The two
    // candidates are different endpoints with different credentials, and
    // guessing lands you on one that may be dead.
    return {
      t: "error",
      message:
        bare.length > 1
          ? `/model: "${spec}" is on ${bare.length} providers -- name one`
          : `/model: no such model "${spec}"`,
    };
  }
  return { t: "intent", intent: { t: "set_model", provider: hit.provider, id: hit.id } };
}

/**
 * Cold or warm, the level is checked against the scale HERE, because pi will
 * not check it: set_thinking_level acks success:true for every string and
 * clamps silently, so an unknown level sent through becomes "off" without a
 * word.
 */
function setEffort(level: string, ctx: CommandContext): CommandOutcome {
  if (level === "" || !ctx.levels.includes(level))
    return { t: "error", message: `/effort ${ctx.levels.join(" | ")}` };
  return { t: "intent", intent: { t: "set_effort", level } };
}

/**
 * The rows the completion bar merges in beside pi's own `get_commands`.
 * Descriptions are LIVE -- the model count and the effort scale come from the
 * catalogue as it stands right now -- which is why this is a function and not a
 * constant.
 */
export function panelCommands(ctx: Pick<CommandContext, "usable" | "levels">): SlashCommand[] {
  return [
    {
      name: "model",
      source: "panel",
      description: `switch model  ·  ${ctx.usable.length} usable`,
      values: ctx.usable.map((m) => `${m.provider}/${m.id}`),
    },
    {
      name: "effort",
      source: "panel",
      description: `thinking level  ·  ${ctx.levels.join(" ")}`,
      values: [...ctx.levels],
    },
    { name: "new", source: "panel", description: "start a fresh conversation" },
    { name: "compact", source: "panel", description: "shrink context now" },
    { name: "name", source: "panel", description: "rename this session" },
    { name: "export", source: "panel", description: "session to an HTML file" },
    {
      name: "restart",
      source: "panel",
      description: "kill the child -- next question is a fresh cold spawn",
    },
  ];
}
