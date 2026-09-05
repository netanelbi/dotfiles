/**
 * One NDJSON record per line on stderr.
 *
 * The host runs as a systemd user unit, so stderr IS the journal --
 * `journalctl --user -u ori-host -o cat | jq` is the whole reader story. That
 * makes a logging library pure weight: no winston, no pino.
 *
 * stdout is reserved: nothing may ever be printed there, because the panel's
 * transport and pi's RPC stdio are both NDJSON and a stray print corrupts a
 * frame.
 */

export type Level = "debug" | "info" | "warn" | "error";

const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function levelFromEnv(): Level {
  const v = Bun.env.ORI_LOG_LEVEL;
  return v === "debug" || v === "info" || v === "warn" || v === "error" ? v : "info";
}

let threshold = ORDER[levelFromEnv()];
let sink: (line: string) => void = (line) => void process.stderr.write(line);

function emit(level: Level, msg: string, fields?: Record<string, unknown>): void {
  if (ORDER[level] < threshold) return;
  sink(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }) + "\n");
}

export const log = {
  debug: (msg: string, fields?: Record<string, unknown>) => emit("debug", msg, fields),
  info: (msg: string, fields?: Record<string, unknown>) => emit("info", msg, fields),
  warn: (msg: string, fields?: Record<string, unknown>) => emit("warn", msg, fields),
  error: (msg: string, fields?: Record<string, unknown>) => emit("error", msg, fields),
  setLevel: (level: Level) => void (threshold = ORDER[level]),
  /** Tests capture instead of spraying the runner's stderr. */
  setSink: (fn: (line: string) => void) => void (sink = fn),
};
