/**
 * End-to-end: the REAL host, on a scratch socket, driven by a REAL client, with
 * a FAKE pi.
 *
 * Everything else in this suite is a unit test with no socket and no child
 * (ARCHITECTURE.md rule 4). This one exists because the wiring is the part no
 * unit test can see: that a `hello` on the wire produces a snapshot, that an
 * `ask` reaches a child's stdin, that the child's events come back out as
 * `Block`s, and that a reconnect adopts the same conversation instead of
 * starting a new one.
 *
 * It touches NOTHING real: its own tmpdir for the socket, the sqlite index, the
 * catalogue files and the detach file, and a five-line shell script standing in
 * for pi. `$XDG_RUNTIME_DIR/ori-agent.sock`, `~/.pi`, and the user's sessions
 * are never opened.
 */

import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Host } from "../../src/main";
import type { CatalogPaths } from "../../src/catalog";
import type { ClientCmd, HostEvent, Turn } from "../../src/protocol";
import { defaultUsageIo, type UsageIo } from "../../src/usage";

/* ------------------------------------------------------------------ *
 * the fake pi
 * ------------------------------------------------------------------ */

const ANSWER = "Hello there";

/**
 * Reads RPC commands off stdin and answers with a canned event sequence. It is
 * a shell script and not a Bun script because the host starts it through
 * `sh -lc '... exec <binary> ...'` (argv.ts) and the fewer runtimes in that
 * chain the fewer ways this can hang.
 *
 * `printf` per line: bash's builtin flushes, and a partially buffered frame
 * would deadlock the test rather than fail it.
 */
const FAKE_PI = `#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *'"type":"prompt"'*)
      printf '%s\\n' '{"type":"response","command":"prompt","success":true}'
      printf '%s\\n' '{"type":"message_start","message":{"role":"assistant"}}'
      printf '%s\\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello"}}'
      printf '%s\\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":" the"}}'
      printf '%s\\n' '{"type":"message_update","usage":{"input":11,"output":3,"totalTokens":14},"assistantMessageEvent":{"type":"text_delta","delta":"re"}}'
      printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"${ANSWER}"}]}}'
      printf '%s\\n' '{"type":"agent_settled"}'
      ;;
    *'"type":"get_session_stats"'*)
      printf '%s\\n' '{"type":"response","command":"get_session_stats","success":true,"data":{"sessionFile":"/fake/session.jsonl","sessionId":"fake-session","contextUsage":{"tokens":14,"contextWindow":9999}}}'
      ;;
    *'"type":"get_state"'*)
      printf '%s\\n' '{"type":"response","command":"get_state","success":true,"data":{"model":{"provider":"fake","id":"fake-model"},"thinkingLevel":"medium","sessionId":"fake-session"}}'
      ;;
    *'"type":"get_available_models"'*)
      printf '%s\\n' '{"type":"response","command":"get_available_models","success":true,"data":{"models":[{"provider":"fake","id":"fake-model","name":"Fake"}]}}'
      ;;
  esac
done
`;

/* ------------------------------------------------------------------ *
 * a client that speaks the panel's half of the protocol
 * ------------------------------------------------------------------ */

class TestClient {
  readonly events: HostEvent[] = [];
  #socket: Awaited<ReturnType<typeof Bun.connect>> | null = null;
  #rest = "";
  #woke: Array<() => void> = [];

  static async connect(path: string): Promise<TestClient> {
    const client = new TestClient();
    client.#socket = await Bun.connect({
      unix: path,
      socket: {
        data(_s, chunk) {
          client.#feed(chunk);
        },
        error() {},
        close() {},
      },
    });
    return client;
  }

  #feed(chunk: Uint8Array): void {
    this.#rest += new TextDecoder().decode(chunk);
    const parts = this.#rest.split("\n");
    this.#rest = parts.pop() ?? "";
    for (const line of parts) {
      if (line === "") continue;
      this.events.push(JSON.parse(line) as HostEvent);
    }
    for (const wake of this.#woke.splice(0)) wake();
  }

  send(cmd: ClientCmd): void {
    this.#socket?.write(JSON.stringify(cmd) + "\n");
  }

  /** Resolves with the first event matching `pred`, scanning what has already
   *  arrived first so a fast host cannot race the waiter. */
  async waitFor<T extends HostEvent>(
    pred: (ev: HostEvent) => ev is T,
    timeoutMs?: number,
  ): Promise<T>;
  async waitFor(pred: (ev: HostEvent) => boolean, timeoutMs?: number): Promise<HostEvent>;
  async waitFor(pred: (ev: HostEvent) => boolean, timeoutMs = 10_000): Promise<HostEvent> {
    const deadline = Date.now() + timeoutMs;
    let seen = 0;
    for (;;) {
      for (; seen < this.events.length; seen++) {
        const ev = this.events[seen]!;
        if (pred(ev)) return ev;
      }
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("timed out waiting for an event");
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(left, 50));
        this.#woke.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  close(): void {
    this.#socket?.end();
    this.#socket = null;
  }
}

/* ------------------------------------------------------------------ */

let dir = "";
let host: Host;
let socket = "";

/** No key, so `OllamaUsage` never reaches the network from a test. */
const offlineUsage: UsageIo = {
  ...defaultUsageIo,
  envKey: () => "",
  fileKey: async () => "",
};

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "ori-host-e2e-"));
  const cfgDir = join(dir, "cfg");
  mkdirSync(cfgDir, { recursive: true });

  const fake = join(dir, "fake-pi");
  writeFileSync(fake, FAKE_PI);
  chmodSync(fake, 0o755);

  const paths: CatalogPaths = {
    settings: join(cfgDir, "settings.json"),
    models: join(cfgDir, "models.json"),
    registry: join(cfgDir, "registry.json"),
    choice: join(cfgDir, "ori-model.json"),
    cache: join(cfgDir, "ori-catalog.json"),
  };

  socket = join(dir, "ori.sock");
  host = new Host({
    socket,
    dbPath: join(dir, "sessions.db"),
    home: dir,
    runtimeDir: dir,
    catalogPaths: paths,
    // The whole point: a fake child, in the tmpdir, with no prompt files and no
    // extensions, so nothing of the user's reaches this process.
    spawn: { binary: fake, workdir: dir, promptFiles: [], extensions: [] },
    usageIo: offlineUsage,
  });
  await host.start();
});

afterAll(async () => {
  await host.stop();
  rmSync(dir, { recursive: true, force: true });
});

test("hello, snapshot, a full turn, and a reconnect that adopts it", async () => {
  const client = await TestClient.connect(socket);
  client.send({ t: "hello", channel: "e2e", version: 1 });

  const hello = await client.waitFor((e): e is Extract<HostEvent, { t: "hello" }> => e.t === "hello");
  expect(hello.version).toBe(1);
  expect(hello.workdir).toBe(dir);

  const first = await client.waitFor(
    (e): e is Extract<HostEvent, { t: "snapshot" }> => e.t === "snapshot",
  );
  // hello lands BEFORE snapshot -- the panel needs a convId before it has
  // anything to draw into.
  expect(client.events.indexOf(hello)).toBeLessThan(client.events.indexOf(first));
  expect(first.convId).toBe(hello.convId);
  expect(first.turns).toEqual([]);
  expect(first.state.busy).toBe(false);
  expect(first.state.warm).toBe(false);

  const before = client.events.length;
  client.send({ t: "ask", text: "hi", images: [] });

  // ---- the block stream ----
  const stream = () => client.events.slice(before);

  const userAdd = await client.waitFor(
    (e): e is Extract<HostEvent, { t: "turn_add" }> => e.t === "turn_add" && e.turn.role === "user",
  );
  expect(userAdd.turn.text).toBe("hi");

  const assistantAdd = await client.waitFor(
    (e): e is Extract<HostEvent, { t: "turn_add" }> =>
      e.t === "turn_add" && e.turn.role === "assistant",
  );
  expect(assistantAdd.turn.pending).toBe(true);
  // The question row exists before the answer row: the view has something to
  // stream into and the conversation never visibly jumps.
  expect(stream().indexOf(userAdd)).toBeLessThan(stream().indexOf(assistantAdd));

  // Queued -> Sent -> Read. The last one is INFERRED from the first token, and
  // it is the only receipt the protocol makes possible.
  const receipts = await client.waitFor(
    (e): e is Extract<HostEvent, { t: "turn_patch" }> =>
      e.t === "turn_patch" && e.turnId === userAdd.turn.id && e.patch.delivery === 2,
  );
  expect(receipts.patch.delivery).toBe(2);

  // `agent_settled` is the idle signal, so this is the one authoritative
  // "the turn is over" the panel gets. It never derives busy.
  await client.waitFor(
    (e) => e.t === "state" && e.patch.busy === false && e.convId === first.convId,
  );

  const deltas = stream().filter(
    (e): e is Extract<HostEvent, { t: "turn_delta" }> =>
      e.t === "turn_delta" && e.turnId === assistantAdd.turn.id,
  );
  // Deltas are APPENDS, not replacements: concatenating them IS the answer.
  expect(deltas.length).toBeGreaterThanOrEqual(3);
  expect(deltas.every((d) => d.field === "text")).toBe(true);
  expect(deltas.map((d) => d.delta).join("")).toBe(ANSWER);

  // The turn was closed, not merely stopped.
  const closed = stream().filter(
    (e): e is Extract<HostEvent, { t: "turn_patch" }> =>
      e.t === "turn_patch" && e.turnId === assistantAdd.turn.id && e.patch.pending === false,
  );
  expect(closed.length).toBe(1);

  // Usage rode along with the deltas and the stats probe agreed with it.
  const usage = stream().filter((e): e is Extract<HostEvent, { t: "usage" }> => e.t === "usage");
  expect(usage.at(-1)?.usage.total).toBe(14);

  // ---- reconnect on the same channel ----
  const before2 = client.events.length;
  client.send({ t: "resync", id: "r1" });
  const resync = await client.waitFor(
    (e): e is Extract<HostEvent, { t: "snapshot" }> =>
      e.t === "snapshot" && client.events.indexOf(e) >= before2,
  );
  expect(resync.turns.length).toBe(2);
  expect(turnOf(resync.turns, "assistant").text).toBe(ANSWER);
  expect(turnOf(resync.turns, "assistant").pending).toBe(false);

  client.close();
  // The 90s orphan grace starts here and is cancelled by the reconnect below;
  // neither is waited on, which is the point -- adoption is instant.
  await Bun.sleep(50);

  const again = await TestClient.connect(socket);
  again.send({ t: "hello", channel: "e2e", version: 1 });
  const adopted = await again.waitFor(
    (e): e is Extract<HostEvent, { t: "snapshot" }> => e.t === "snapshot",
  );

  // Same conversation, byte for byte -- not a new one, and not a re-read.
  expect(adopted.convId).toBe(first.convId);
  expect(adopted).toEqual(resync);
  again.close();
}, 30_000);

function turnOf(turns: Turn[], role: Turn["role"]): Turn {
  const t = turns.find((x) => x.role === role);
  if (!t) throw new Error(`no ${role} turn in the snapshot`);
  return t;
}
