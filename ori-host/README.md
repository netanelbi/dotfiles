# ori-host

The engine behind the Ori assistant panel. It owns the pi children, the whole
conversation state and every side effect; the Quickshell panel receives `Block`s
and draws them.

It replaces the Python broker (`scripts/.local/bin/ori-agent`, 1043 lines) and
the conversation half of `PiSession.qml` (3593 lines) — which between them
parsed pi's wire protocol **twice, in two languages, and neither was pi's**. The
design and the measured facts behind it are in [ARCHITECTURE.md](ARCHITECTURE.md);
the wire contract is [`src/protocol.ts`](src/protocol.ts). Read those two before
changing anything here.

## Build and run

```bash
bun install          # devDependencies only -- there are ZERO runtime deps
bun test             # every module, no socket, no child, plus one e2e smoke
bun run typecheck    # tsc --noEmit
bun run build        # -> dist/ori-host, one binary
bun run start        # from source, for development
```

`bun run build` produces a single ~80 MB executable with `--smol` baked in and
`.env` / `bunfig.toml` autoloading **disabled** — a compiled binary otherwise
reads both from whatever directory systemd started it in.

## Install

The compiled binary is ~80 MB, so unlike everything else in this dotfiles tree
it is **not in the repo and not stowed** — `ori-host/.gitignore` excludes
`dist/`, and the binary is built per machine and *copied* into place. That is
the one job of `scripts/install.ts`:

```bash
cd ori-host
bun install
bun run scripts/install.ts            # build, then -> ~/.local/bin/ori-host
bun run scripts/install.ts --dry-run  # just print where it would go
```

It runs no `systemctl` of its own — enabling a unit and restarting a daemon you
may be talking to are yours to decide — so it prints the rest and stops:

```bash
stow scripts                                     # once, for the unit file
systemctl --user daemon-reload
systemctl --user disable --now ori-agent.socket  # see below
systemctl --user enable --now ori-agent.service
journalctl --user -u ori-agent -f -o cat | jq
```

**Upgrading** is the same script again, then `systemctl --user restart
ori-agent`. The install writes to `ori-host.new` and renames it over the target,
because writing into a running executable's inode is `ETXTBSY`; the running host
keeps its old inode until you restart it.

`ori-agent.socket` must be **disabled**, and the unit is gone from this repo.
Bun cannot adopt an fd systemd hands it (`new net.Socket(fd)` is write-only in
Bun), so a socket-activated host could answer nobody. Left enabled, that unit
would keep owning `$XDG_RUNTIME_DIR/ori-agent.sock` and the panel would connect
to a listener with nothing behind it — the exact failure `PiSession`'s 8-second
hello watchdog existed for. The host binds the path itself now and unlinks a
stale file at startup, after probing it, so it can never unlink a socket another
live host is serving.

`ExecStart` still goes through `fish -lc`: a user unit starts from an almost
empty environment, and that login shell is what supplies `~/.bun/bin` on `PATH`
and `OLLAMA_API_KEY` without either reaching a unit file or the journal.

## Layout

| file | what it owns |
|---|---|
| `src/protocol.ts` | the host↔panel contract. No imports, pure types + framing. |
| `src/transport.ts` | `Bun.listen` unix server, NDJSON framing, backpressure, channel identity. |
| `src/pi/argv.ts` | the pi command line. Pure. |
| `src/pi/pi-types.ts` | pi's OWN declarations, re-exported. Nothing is transcribed. |
| `src/pi/child.ts` | one `pi --mode rpc` child: spawn, framing, typed send/request, death. |
| `src/conversation.ts` | pi events → `Block`s. Turn state, the steer seam, usage, cost. |
| `src/pool.ts` | N conversations, one active. Idle kill, orphan reap, the parked cap. |
| `src/store.ts` | `bun:sqlite` session index + streaming transcript reads. |
| `src/catalog.ts` | models / providers / thinking levels, and the config watchers. |
| `src/commands.ts` | `/model /effort /new /compact /name /export /restart`. Pure dispatch. |
| `src/images.ts` | `wl-paste` capture, mime sniff, base64, staged attachments. |
| `src/detach.ts` | the `ORI_DETACH_PATH` side channel. |
| `src/usage.ts` | Ollama plan usage. Event-driven, never polled. |
| `src/log.ts` | NDJSON to stderr, i.e. to the journal. |
| `src/main.ts` | **wiring only.** |

Every module is unit-testable with no socket and no child process: side effects
arrive through a small injected interface with a default implementation. The one
exception is `tests/e2e/smoke.test.ts`, which starts the real host on a scratch
socket in a tmpdir with a five-line shell script standing in for pi, and asserts
the whole block stream — hello → snapshot → turn_add(user) → turn_add(assistant)
→ deltas → settled → `busy:false` — then reconnects on the same channel and
asserts the snapshot is identical. It never touches the real socket path, the
real pi, or the user's sessions.

### `main.ts` and the `Agent` seam

`main.ts` is wiring, with one piece of real code in it. `pool.ts` declares a
narrow `Conversation` (id, busy, snapshot, killChild) so it can be tested with no
child process, and `conversation.ts` is a pure state machine that has never heard
of a pi process. `Agent` is the join: one `PiChild`, one `Conversation`, one
`DetachChannel`. It holds no policy — where it has to choose, the comment names
the module the rule came from.

## Known gaps

* **A resumed session's transcript is not rebuilt into turns.** `get_entries`
  reaches the host and updates the index row (label, count) so the picker stays
  correct, but nothing converts pi's entries into `Turn[]`, so activating a
  disk-only session shows an empty transcript until the next question. The
  streaming reader (`store.readTranscript`, no 120-entry cap) and the hook
  (`ConversationDeps.onEntries`) are both in place; the mapping is not.
* **Subagent activity is read but not published.** `Catalog.agentActivity`
  tracks the pi subagent registry, and `BgJob.activity` is the field it belongs
  in, but the two are not joined.
* **`notice` and `error` are still routed by the emitter, not by the event.**
  Both now carry an optional `convId` (absent means "the active conversation"),
  and `pool.ts` uses it to report a parked child's death the moment it happens.
  But `main.ts`'s per-conversation gate still drops everything a parked
  conversation emits, so a parked `/export` or compaction notice does not reach
  the panel; the gate has to start reading `ev.convId` instead of the id of the
  conversation that emitted it.
