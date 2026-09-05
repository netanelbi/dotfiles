# ori-host — architecture and build spec

The engine behind the Ori assistant panel. Replaces **both** the Python broker
(`scripts/.local/bin/ori-agent`, 1043 lines) and the conversation half of
`quickshell/.config/quickshell/PiSession.qml` (3593 lines).

## Why this exists

Today the pi wire protocol is parsed **twice, in two languages, and neither is
pi's**: once in Python, once again in QML. The two halves then keep separate,
drifting copies of the same state — `busy`, "is this message already on disk",
the opening question of a turn. Every hard bug traced back to that split.

pi ships full TypeScript declarations for its own protocol
(`@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-types.d.ts`,
`dist/modes/json-event.d.ts`). The host imports them. Nothing is transcribed.

## Rules

1. **The panel is pixels.** It receives `Block`s and draws them. It never parses
   a pi frame, never holds conversation state, never touches a config file,
   never encodes an image.
2. **Zero npm dependencies.** Bun 1.4.0 built-ins only — `bun:sqlite`,
   `Bun.spawn`, `Bun.listen`, `fs.watch`, `bun:test`, `Buffer.toString("base64")`.
   No express/ws/chokidar/jest/uuid/dotenv. See the table at the bottom.
3. **Import pi's types. Never re-declare a pi frame shape.**
4. **Every module is unit-testable with no socket and no child process.**
   Side effects go behind an injected interface.
5. Node-`readline` is **not** protocol-compliant for pi RPC (it also splits on
   U+2028/U+2029, valid inside JSON strings). Split on `\n` only.

## Transport — NDJSON over a unix socket

Quickshell cannot do WebSocket (`qt6-websockets` is not installed) and cannot do
length-prefixed framing (`DataStreamParser` is `isCreatable: false`, so the C++
split happens before QML sees bytes). The only push transport is
`Quickshell.Io.Socket` + `SplitParser { splitMarker: "\n" }`.

So: **newline-delimited JSON, both directions**, over `Bun.listen({ unix })`.
Contract: `JSON.stringify(obj) + "\n"`. `JSON.stringify` escapes newlines, so a
record never contains a bare `\n`.

Socket path: `$XDG_RUNTIME_DIR/ori-agent.sock` (never `/tmp` —
`fs.protected_regular` once locked root out of a lock file there).

**Systemd changes shape.** Bun cannot adopt a systemd-passed fd
(`new net.Socket(fd)` is write-only in Bun). Drop `ori-agent.socket`; the
service creates its own listener and must `unlink` a stale socket file at
startup. Keep `ExecStart=/usr/bin/fish -lc '…'` — a user unit starts from an
almost-empty environment, and `fish -lc` is what puts `~/.bun/bin` on PATH and
`OLLAMA_API_KEY` in the environment without either reaching a unit file or the
journal.

## Module map

```
src/
  protocol.ts      host↔panel wire contract. No imports. Pure types + guards.
  transport.ts     Bun.listen unix server, NDJSON framing, Conn objects.
  pi/argv.ts       build the pi command line (provider/model/thinking/session/
                   extensions/system prompts). Pure function → string[].
  pi/child.ts      one pi child: spawn, NDJSON stdio, typed send/recv, exit.
  conversation.ts  pi events → Block[]. Turn state, the steer seam, usage.
  pool.ts          N conversations. Active/parked. Idle kill, orphan reap.
  store.ts         bun:sqlite session index + transcript offsets.
  catalog.ts       models / providers / thinking levels + config file watchers.
  commands.ts      /model /effort /new /compact /name /export /restart.
  images.ts        wl-paste capture, mime sniff, base64.
  detach.ts        the ORI_DETACH_PATH side channel.
  usage.ts         Ollama plan usage (fetch, not XHR).
  log.ts           ~20-line NDJSON logger to stderr. No winston/pino.
  main.ts          wiring only.
```

## The host↔panel contract (`protocol.ts`)

The panel's whole world. A `Block` is a thing to draw; the panel never computes
one.

Design notes that matter:

- **Blocks are addressed by stable id**, never by array index. The old code
  keyed five parallel maps (`toolLog`, `turnCost`, …) on a row index and had to
  `shiftRowKeys()` on every steer insert. Ids remove that class of bug.
- **Deltas are appends, not replacements.** `block_delta` carries only the new
  text. The panel concatenates. This is what makes streaming cheap.
- **`tool_execution_update.partialResult` from pi is cumulative, not a delta** —
  the host must diff it before emitting a `block_delta`, or the panel will
  render the prefix N times.
- The panel gets **one** authoritative `turn_state`; it never derives `busy`.

## What moves, in full

Everything in the inventory below is host-side now. Sources are given so the
builder can read the measured behaviour rather than re-derive it.

| area | old location | notes that must survive |
|---|---|---|
| socket, reconnect, watchdogs | `PiSession.qml:3288-3424` | retry 1s ×5 then hard error; `helloWatchdog` 8000ms exists because a systemd `.socket` connects even with nothing behind it — **that whole class of bug disappears** once the service owns its listener, but keep a handshake deadline anyway |
| pi frame ingest | `PiSession.qml:2722-3179` | full switch; `agent_settled` is the idle signal, **not** `agent_end` |
| turn model | `PiSession.qml:365-907, 823-870` | `grow()` was a per-token full-string concat + signal — host-side it is an append to an array |
| steer seam | `PiSession.qml:998-1225` | seam fires on `message_end` role=`user`; match the echoed text, split the row, re-key. `stopReason` is **not** a valid seam discriminator (refuted by wire capture) |
| background jobs | `PiSession.qml:536-658, 3033-3070` | `bgCount` excludes `kind==="speak"`; added on `tool_execution_end` when `details.backgrounded`, dropped on `message_end` `customType==="bg_process_done"` |
| session index | `PiSession.qml:1610-1767` | was `ori-sessions.json`, re-stringified once per settled turn → now `bun:sqlite` WAL |
| transcript restore | `PiSession.qml:1691-1703` | was `split("\n")` on a ~9 MB file **before** applying a 120-entry cap. Host-side: stream + `file.slice()` from a stored offset. **The 120 cap goes away.** |
| model catalogue | `PiSession.qml:2062-2668` | `ori-model.json` was rewritten with the full catalogue on every effort change |
| usage / cost / compaction | `PiSession.qml:667-790, 2485-2549` | `usageEstimated`/`usageStaleAbove` reject a stale post-compaction reading — keep that |
| images | `PiSession.qml:1305-1467` | hand-rolled base64 over ≤12 MB on the UI thread, 2170 ms measured. Now `Buffer.toString("base64")`, **1.34 ms / 8 MB** |
| config watchers | `PiSession.qml:2161-2235` | `~/.pi/agent/{settings,models}.json`, `~/.pi/agent/subagents/registry.json`. `models.json` had two independent readers. Debounce `fs.watch` ~50 ms |
| panel commands | `PiSession.qml:2458-2668` | `/model` and `/effort` must work with **no agent running** |
| spawn + argv | `ori-agent:298-401` | `--append-system-prompt` paths are checked with `existsSync()` and `~` is **not** expanded — an unexpanded path is silently treated as literal prompt text |
| idle kill / orphan reap | `ori-agent:269, 426-554` | 600 s idle, 90 s orphan grace |
| hold / replay buffer | `ori-agent:445, 743-852` | `response` frames pass the hold, events do not |
| detach side channel | `ori-agent:566-657` | fixed-width 96-byte record, single `os.write`, carries pid so subagents ignore it |

## What stays in QML

The scroll/stick machine (`AssistantPanel.qml:591-1128`), selection, composer,
key handling, the frame clock, `Fmt.qml` markdown→RichText, `TurnDelegate`,
`ToolLine`, `InlineImage`, `CommandBar`, `SessionPicker`, `BackgroundTray`.

These hold real, hard-won fixes. **Do not rewrite them.** They get rebound from
`PiSession.*` to `OriClient.*`.

## Multi-session

Per `docs/specs/multi-session.md`, which is the requirement:

- Ctrl+N and Ctrl+R **park**, never stop. A parked conversation's pi child keeps
  running and its turn finishes in the background.
- The picker lists parked sessions with a busy indicator; picking one is
  instant (already in memory).
- Ctrl+C applies to the active conversation only.
- If a parked busy child dies, the turn shows as failed — never silently dropped.
- Cap 4 parked; when full the oldest idle one is flushed to disk-resume only.

`pi --session-id <id>` is idempotent ("use exact project session ID, creating it
if missing"), so a conversation maps to one child, one session id, one row.

## Verify

```bash
cd ori-host
bun test                       # every module, no socket, no child
bun run typecheck              # tsc --noEmit
bun build --compile ...        # ships one binary
```

Plus an end-to-end smoke: start the host on a scratch socket, drive it with
`bun run tests/e2e/drive.ts`, assert the Block stream.

## Bun 1.4 built-ins — use these, add nothing

| instead of | use |
|---|---|
| express / ws | `Bun.listen({unix})` (NDJSON; QML has no WebSocket) |
| better-sqlite3 | `bun:sqlite` (`{strict:true}`, `PRAGMA journal_mode=WAL`) |
| chokidar | `fs.watch(dir,{recursive:true})` + your own ~50 ms debounce |
| jest / vitest / sinon | `bun:test` (`mock`, `spyOn`, `mock.module`, fake timers) |
| execa / cross-spawn | `Bun.spawn` (stdin is a `FileSink`; iterate `proc.stdout`) |
| uuid / nanoid | `crypto.randomUUID()`, `Bun.randomUUIDv7()` |
| dotenv | automatic `.env` + `Bun.env` |
| node-fetch / axios | global `fetch` |
| glob | `Bun.Glob` |
| js-yaml | `Bun.YAML` |
| winston / pino | ~20 lines to a `Bun.file().writer()` |
| pkg / nexe | `bun build --compile` |

Traps found while checking:

- **`Bun.file().lines()` does not exist** on 1.4.0. For JSONL use
  `Bun.file(p).stream()` + `TextDecoderStream` and split on `\n` yourself.
  `file.slice(start,end)` seeks cheaply to a stored byte offset.
- `Bun.file().writer()` **does not truncate** — right for appending JSONL, a
  trap if you meant to overwrite.
- **`Bun.base64` does not exist.** `Buffer.from(bytes).toString("base64")` is
  the fastest path (1.34 ms / 8 MB, measured; `.toBase64()` is slower).
- `mock.restore()` restores spies but **not** `mock.module()` replacements.
- A filesystem-path unix socket is **not** unlinked on exit — unlink stale at
  startup.
- Compiled binaries autoload `.env` and `bunfig.toml` from CWD — set
  `autoloadDotenv: false, autoloadBunfig: false` in `Bun.build({compile})`.
