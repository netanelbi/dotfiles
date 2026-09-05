/**
 * How much of the Ollama Cloud allowance is spent. Replaces Usage.qml's
 * XMLHttpRequest with `fetch`.
 *
 * ----------------------------------------------------------------- the payload
 * GET https://ollama.com/api/usage, bearer token. Undocumented but stable:
 *
 *   { "activity": { "cost": "0.00000", ... },
 *     "limits": { "session": { "usage": 0.01,  "models": [...] },
 *                 "weekly":  { "usage": 0.007, "models": [...] } } }
 *
 * `usage` is a FRACTION of the allowance (0.011 = 1.1%), not a percentage and
 * not a token count -- verified against request_count moving while usage stayed
 * under 0.02, and again at 418 weekly requests / usage 0.007. `activity` is
 * billed spend and is all zeroes on this plan, so only `limits` is parsed.
 *
 * The origin is used rather than the proxy models.json points pi at: both were
 * measured returning an identical body in 0.70s, and the proxy fronts
 * INFERENCE, while this is an account readout that belongs to the account.
 *
 * ------------------------------------------------------------------ no polling
 * The number moves for exactly one reason -- a turn was spent against the plan
 * -- and the host already knows when that happens. So the caller refreshes on
 * settle and on panel-open, and nothing here runs on a timer.
 */

export const USAGE_URL = "https://ollama.com/api/usage";

/** Long enough that a burst of short turns is one request, short enough that
 *  the number is never stale by the time you look at it. */
const THROTTLE_MS = 60_000;

/** QML's XHR had no timeout at all -- a request to an unroutable address was
 *  still open 20s later with no handler ever called. fetch has AbortSignal, so
 *  this is a real deadline rather than a watchdog bolted on beside one. */
const TIMEOUT_MS = 8_000;

/** Floor between two 401-driven re-reads of models.json. A key that is simply
 *  wrong 401s forever, and the caller refreshes on every settled turn, so
 *  without a floor a rejected key would stat and parse that file once per turn
 *  for the life of the host. A rotation is picked up within this window, which
 *  is as immediate as a plan readout ever needs to be. */
const KEY_REREAD_MS = 60_000;

export interface UsageIo {
  fetch(url: string, init: { headers: Record<string, string>; signal: AbortSignal }): Promise<{
    status: number;
    text(): Promise<string>;
  }>;
  /** The env var, "" when unset. Tried FIRST because the host is started from a
   *  fish login shell that sources it, so the first fetch can go out on the
   *  event that asked for it with no file IO. */
  envKey(): string;
  /** models.json -> providers.ollama.apiKey, "" when there is none. Wire this
   *  to Catalog.ollamaApiKey so models.json keeps exactly one reader; the
   *  default below exists only so this module stands alone in a test. */
  fileKey(): Promise<string>;
  now(): number;
}

export const defaultUsageIo: UsageIo = {
  async fetch(url, init) {
    return await fetch(url, init);
  },
  envKey() {
    return Bun.env["OLLAMA_API_KEY"] ?? "";
  },
  async fileKey() {
    try {
      const f = Bun.file(`${Bun.env["HOME"] ?? ""}/.pi/agent/models.json`);
      if (!(await f.exists())) return "";
      const providers = ((await f.json()) as { providers?: Record<string, { apiKey?: string }> })
        .providers;
      return providers?.["ollama"]?.apiKey ?? "";
    } catch {
      return "";
    }
  },
  now() {
    return Date.now();
  },
};

export interface UsageState {
  /** Fractions of their own separate allowances, or null for "we have not been
   *  told". Deliberately NOT 0 -- "unknown" and "none of it is spent" are
   *  different facts and a footer that renders them the same way is lying about
   *  the second one. */
  session: number | null;
  weekly: number | null;
  /** Last failure, "" when the last fetch worked. */
  error: string;
}

export class OllamaUsage {
  session: number | null = null;
  weekly: number | null = null;
  error = "";

  readonly #io: UsageIo;
  #key = "";
  #lastFetch = 0;
  #lastKeyRead = 0;
  #inFlight = false;

  constructor(io: UsageIo = defaultUsageIo) {
    this.#io = io;
  }

  get known(): boolean {
    return this.session !== null || this.weekly !== null;
  }

  get state(): UsageState {
    return { session: this.session, weekly: this.weekly, error: this.error };
  }

  /** `force` skips the throttle; the panel-open and settled paths do not. */
  async refresh(force = false): Promise<UsageState> {
    if (this.#inFlight) return this.state;
    if (!force && this.#lastFetch > 0 && this.#io.now() - this.#lastFetch < THROTTLE_MS)
      return this.state;

    this.#inFlight = true;
    try {
      if (this.#key === "") {
        this.#key = this.#io.envKey();
        if (this.#key === "") {
          this.#lastKeyRead = this.#io.now();
          this.#key = await this.#io.fileKey();
        }
      }
      if (this.#key === "") {
        this.error = "no key";
        return this.state;
      }

      let status = await this.#get();
      if (status === 401) {
        // The key in hand is stale. A rotated key lands in models.json
        // immediately and in this process's environment only after a re-login,
        // so on a 401 the file is the NEWER of the two -- without this retry a
        // stale environment leaves the readout dead until the next logout.
        //
        // Deliberately NOT latched on "we already read the file once": the host
        // is a daemon that runs for days and a key can rotate more than once in
        // that time, so a latch means the second rotation is never picked up and
        // only a restart fixes the footer. A cooldown instead of a latch -- so a
        // permanently rejected key cannot turn every settled turn into a file
        // read -- and the difference check keeps it from re-sending the key that
        // was just refused.
        const now = this.#io.now();
        if (this.#lastKeyRead === 0 || now - this.#lastKeyRead >= KEY_REREAD_MS) {
          this.#lastKeyRead = now;
          const fresh = await this.#io.fileKey();
          if (fresh !== "" && fresh !== this.#key) {
            this.#key = fresh;
            status = await this.#get();
          }
        }
      }
      if (status === 401) this.error = "key rejected";
      return this.state;
    } finally {
      this.#inFlight = false;
    }
  }

  /** Returns the HTTP status so the caller can act on 401; everything else is
   *  recorded on `error`. Returns 0 for a request that never happened. */
  async #get(): Promise<number> {
    let res: { status: number; text(): Promise<string> };
    try {
      res = await this.#io.fetch(USAGE_URL, {
        headers: { Authorization: `Bearer ${this.#key}` },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (e) {
      // A timeout and a dead network are told apart, because "it broke" twice
      // over is not a diagnosis. Neither clears the numbers already on screen.
      this.error = e instanceof Error && e.name === "TimeoutError" ? "timed out" : "offline";
      return 0;
    }
    if (res.status === 401) return 401;
    if (res.status !== 200) {
      this.error = `HTTP ${res.status}`;
      return res.status;
    }
    try {
      const body: unknown = JSON.parse(await res.text());
      const limits = (body as { limits?: Record<string, { usage?: unknown }> }).limits;
      // Read through rather than destructured: a plan reporting only one of the
      // two windows must leave the other unknown, not take the whole parse down.
      const num = (v: unknown): number | null => (typeof v === "number" ? v : null);
      this.session = num(limits?.["session"]?.usage);
      this.weekly = num(limits?.["weekly"]?.usage);
      this.error = this.known ? "" : "no limits";
      this.#lastFetch = this.#io.now();
    } catch {
      // A usage readout is never worth breaking anything else over. The last
      // good numbers stay; only `error` moves.
      this.error = "bad response";
    }
    return 200;
  }
}

/**
 * A fraction as a percentage. Under a tenth of a percent "0.0%" reads as broken
 * and "<0.1%" reads as fine.
 */
export function formatPercent(f: number | null): string {
  if (f === null || f < 0) return "—";
  const p = f * 100;
  if (p > 0 && p < 0.1) return "<0.1%";
  return (p < 10 ? p.toFixed(1) : String(Math.round(p))) + "%";
}
