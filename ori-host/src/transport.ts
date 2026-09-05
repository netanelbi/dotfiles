/**
 * The socket surface the panel talks to: NDJSON over a filesystem unix socket.
 *
 * Why not Bun.serve + WebSocket, which would be less code: Quickshell has no
 * WebSocket type at all (qt6-websockets is not installed here), and it cannot
 * do length-prefixed framing either -- `DataStreamParser` is `isCreatable:
 * false`, so the C++ side splits the byte stream before QML ever sees it. The
 * only push transport the panel can consume is `Quickshell.Io.Socket` +
 * `SplitParser { splitMarker: "\n" }`. Hence raw unix socket, newline-delimited
 * JSON, both directions.
 *
 * Everything below is deliberately split so it can be tested with no socket at
 * all: `Conn.feed()` is pure chunk-in/frames-out, and `Conn` writes through the
 * narrow `WritableSocket` interface so the backpressure queue can be driven by
 * a fake that accepts N bytes per call.
 */

import { chmodSync, existsSync, unlinkSync } from "node:fs";
import { decodeLines, encode, type ClientCmd, type HostEvent } from "./protocol";
import { log } from "./log";

const encoder = new TextEncoder();

/**
 * The slice of Bun's `Socket` a `Conn` actually uses. Narrow on purpose: a test
 * fake implements two methods, and nothing here can accidentally reach for a
 * socket feature the fake does not have.
 */
export interface WritableSocket {
  /** Returns the number of BYTES accepted, which may be less than offered. */
  write(data: Uint8Array): number;
  end(): unknown;
}

/**
 * A pathological client that stops reading (panel wedged mid-frame) would
 * otherwise grow this queue without bound -- snapshots run to ~9 MB. Past this
 * we drop the connection instead: a reconnect gets a fresh snapshot, whereas
 * dropping individual queued frames would silently desync the panel forever.
 */
const MAX_QUEUED_BYTES = 64 * 1024 * 1024;

export class Conn {
  /** Empty until the `hello` handshake completes. */
  channel = "";

  /** Unsent tails, in order. Only non-empty while the socket is backed up. */
  private queue: Uint8Array[] = [];
  private queuedBytes = 0;
  private writable = true;

  /**
   * A streaming decoder, NOT `chunk.toString()`. A 2 MB frame arrives in many
   * chunks and the split lands wherever the kernel put it -- mid-UTF-8 as
   * easily as anywhere else. `{ stream: true }` holds the partial code point
   * back; decoding each chunk independently would corrupt it into U+FFFD.
   */
  private decoder = new TextDecoder("utf-8");
  private rest = "";

  constructor(
    readonly id: number,
    private socket: WritableSocket,
  ) {}

  get alive(): boolean {
    return this.writable;
  }

  /** Bytes accepted by `send` but not yet handed to the kernel. */
  get pending(): number {
    return this.queuedBytes;
  }

  /**
   * Split a chunk into frames. Malformed lines are dropped with a log line
   * rather than thrown: one torn record must never kill a long-lived
   * connection, and a client that can send a torn record can send another.
   *
   * The shape check is minimal on purpose -- `t` must be a string. protocol.ts
   * ships no runtime guard, so validating the payload is the command layer's
   * job; the transport only guarantees "this is an object that claims a tag".
   */
  feed(chunk: Uint8Array): ClientCmd[] {
    this.rest += this.decoder.decode(chunk, { stream: true });
    const { msgs, bad, rest } = decodeLines(this.rest);
    this.rest = rest;
    for (const line of bad) {
      log.warn("dropped malformed frame", { conn: this.id, len: line.length });
    }
    const out: ClientCmd[] = [];
    for (const m of msgs) {
      if (typeof m !== "object" || m === null || typeof (m as { t?: unknown }).t !== "string") {
        log.warn("dropped untagged frame", { conn: this.id });
        continue;
      }
      out.push(m as ClientCmd);
    }
    return out;
  }

  send(ev: HostEvent): void {
    if (!this.writable) return;
    const bytes = encoder.encode(encode(ev));
    // Order matters more than latency: once anything is queued, everything
    // queues behind it, or a small event would overtake a large snapshot.
    if (this.queue.length > 0) {
      this.enqueue(bytes);
      return;
    }
    const n = this.accept(bytes);
    if (n < bytes.length) this.enqueue(bytes.subarray(n));
  }

  /** Called from the socket's `drain` handler: the kernel wants more. */
  drain(): void {
    while (this.writable && this.queue.length > 0) {
      const head = this.queue[0]!;
      const n = this.accept(head);
      if (n < head.length) {
        this.queue[0] = head.subarray(n);
        this.queuedBytes -= n;
        return;
      }
      this.queue.shift();
      this.queuedBytes -= head.length;
    }
  }

  /** Our own hangup. */
  close(): void {
    this.stopWriting();
    try {
      this.socket.end();
    } catch {
      /* already gone */
    }
  }

  /**
   * A newer connection took this channel. The old writer is silenced BEFORE its
   * close event lands, because the failure this prevents is a stale connection
   * resurrecting: ori-agent:485-494 carried a `conn_token` for exactly this, so
   * that a superseded read loop's `finally` could not clear the writer the live
   * client had just installed. Here the same guarantee is identity-based -- a
   * displaced Conn is not writable and disowns its channel.
   *
   * Dropping `channel` here rather than relying on a map lookup is deliberate:
   * Bun can run the `close` handler synchronously inside `end()`, i.e. before
   * the caller has re-pointed the channel at the new connection, and a lookup
   * would then still find this conn and fire a spurious `onGone` -- which the
   * pool would answer by starting an orphan grace on a channel that just got a
   * live client. Measured: it fired on the very first run of this test.
   */
  displace(): void {
    this.channel = "";
    this.stopWriting();
    try {
      this.socket.end();
    } catch {
      /* already gone */
    }
  }

  /** The peer went away; nothing more can be written. */
  markClosed(): void {
    this.stopWriting();
  }

  private stopWriting(): void {
    this.writable = false;
    this.queue = [];
    this.queuedBytes = 0;
  }

  private accept(bytes: Uint8Array): number {
    let n: number;
    try {
      n = this.socket.write(bytes);
    } catch {
      this.stopWriting();
      return bytes.length; // swallow: the close handler will do the bookkeeping
    }
    // Bun returns a negative count for a socket that is already gone.
    return n < 0 ? 0 : Math.min(n, bytes.length);
  }

  private enqueue(bytes: Uint8Array): void {
    this.queue.push(bytes);
    this.queuedBytes += bytes.length;
    if (this.queuedBytes > MAX_QUEUED_BYTES) {
      log.error("client not draining -- dropping connection", {
        conn: this.id,
        channel: this.channel,
        pending: this.queuedBytes,
      });
      this.close();
    }
  }
}

export interface TransportHandlers {
  /**
   * The handshake completed. `displaced` is true when a live writer was kicked
   * off this channel (a Quickshell hot reload does this every time).
   *
   * Channel identity is durable in the POOL, not here: this map only routes
   * writes, so a client that reconnects after its predecessor already closed
   * arrives with `displaced: false` and must still adopt by channel name.
   */
  onHello(conn: Conn, channel: string, displaced: boolean): void;
  onCommand(conn: Conn, cmd: ClientCmd): void;
  /**
   * The connection that OWNED `channel` went away. A displaced connection never
   * fires this -- its channel already belongs to someone else. This is the
   * signal the pool starts its 90 s orphan grace on (ori-agent:426-554).
   */
  onGone(conn: Conn, channel: string): void;
}

/** fs + probe side effects, injected so startup logic is testable. */
export interface TransportFs {
  exists(path: string): boolean;
  unlink(path: string): void;
  chmod(path: string, mode: number): void;
  /** True when something is actually accepting connections at `path`. */
  probe(path: string): Promise<boolean>;
}

export const nodeFs: TransportFs = {
  exists: (p) => existsSync(p),
  unlink: (p) => unlinkSync(p),
  chmod: (p, mode) => chmodSync(p, mode),
  probe: async (p) => {
    try {
      const s = await Bun.connect({ unix: p, socket: { data() {}, error() {}, close() {} } });
      s.end();
      return true;
    } catch {
      return false;
    }
  },
};

/**
 * `$XDG_RUNTIME_DIR/ori-agent.sock`. Never /tmp: `fs.protected_regular` once
 * locked root out of a netanel-owned lock file there, and every TDP re-apply
 * silently skipped for weeks. If the runtime dir is missing we fail loudly
 * rather than fall back.
 */
export function socketPath(env: Record<string, string | undefined> = Bun.env): string {
  const dir = env.XDG_RUNTIME_DIR;
  if (!dir) throw new Error("XDG_RUNTIME_DIR is unset; refusing to place the socket in /tmp");
  return `${dir}/ori-agent.sock`;
}

/**
 * Take ownership of the socket path.
 *
 * A filesystem unix socket is NOT unlinked when the process that bound it
 * exits, so a leftover file is the normal case after a crash. But the file
 * alone cannot tell us whether a host is alive behind it -- only a connect
 * can. If the connect SUCCEEDS another host is serving and we must exit rather
 * than unlink its socket out from under it, which would leave it running and
 * unreachable.
 */
export async function claimSocketPath(path: string, fs: TransportFs = nodeFs): Promise<void> {
  if (!fs.exists(path)) return;
  if (await fs.probe(path)) {
    throw new Error(`another ori-host is already listening on ${path}`);
  }
  log.info("unlinking stale socket", { path });
  fs.unlink(path);
}

export interface OriServer {
  readonly path: string;
  /** The live connection holding `channel`, if any. */
  connFor(channel: string): Conn | undefined;
  conns(): Conn[];
  /** Close every connection, stop listening, and remove the socket file. */
  stop(): void;
}

export interface ServeOptions {
  path: string;
  handlers: TransportHandlers;
  fs?: TransportFs;
}

export async function serve(opts: ServeOptions): Promise<OriServer> {
  const fs = opts.fs ?? nodeFs;
  const { path, handlers } = opts;

  await claimSocketPath(path, fs);

  const channels = new Map<string, Conn>();
  let nextId = 0;

  const hello = (conn: Conn, cmd: Extract<ClientCmd, { t: "hello" }>): void => {
    // A parked client hellos with no channel. Nothing can ever adopt it; the
    // id-derived name exists only so the pool can key it like any other.
    const channel = cmd.channel || `anon-${conn.id}`;

    // A second hello on the same connection re-registers it. Drop the old key
    // first, or the pool keeps state alive under a name no client will say
    // again -- ori-agent:879-884 learned this the hard way.
    if (conn.channel && channels.get(conn.channel) === conn) channels.delete(conn.channel);

    const prev = channels.get(channel);
    const displaced = prev !== undefined && prev !== conn;
    if (prev && prev !== conn) {
      log.info("displacing previous client", { channel, old: prev.id, new: conn.id });
      prev.displace();
    }
    conn.channel = channel;
    channels.set(channel, conn);
    // Same containment as onCommand below: a hello and the first ask routinely
    // arrive in ONE chunk (the panel's reconnect-and-resend burst), so a throw
    // out of the pool here would abandon the rest of the chunk -- the user's
    // message vanishes with nothing on stderr, because Bun swallows exceptions
    // thrown from the socket data callback and leaves the connection open.
    // Routing is already committed above, so the connection stays usable.
    try {
      handlers.onHello(conn, channel, displaced);
    } catch (e) {
      log.error("hello handler threw", { conn: conn.id, channel, err: String(e) });
    }
  };

  const server = Bun.listen<Conn>({
    unix: path,
    socket: {
      open(socket) {
        const conn = new Conn(++nextId, socket);
        socket.data = conn;
        log.debug("client connected", { conn: conn.id });
      },
      data(socket, chunk) {
        const conn = socket.data;
        for (const cmd of conn.feed(chunk)) {
          if (cmd.t === "hello") {
            hello(conn, cmd);
            continue;
          }
          if (!conn.channel) {
            // The contract is that hello comes first; anything before it has no
            // conversation to belong to.
            log.warn("frame before hello, dropped", { conn: conn.id, t: cmd.t });
            continue;
          }
          try {
            handlers.onCommand(conn, cmd);
          } catch (e) {
            log.error("command handler threw", { conn: conn.id, t: cmd.t, err: String(e) });
          }
        }
      },
      drain(socket) {
        socket.data.drain();
      },
      close(socket) {
        const conn = socket.data;
        conn.markClosed();
        log.debug("client gone", { conn: conn.id, channel: conn.channel });
        if (conn.channel && channels.get(conn.channel) === conn) {
          const channel = conn.channel;
          channels.delete(channel);
          // Unguarded, a throw here escapes into Bun's close callback and is
          // swallowed; the map entry is already gone, so the only observable
          // effect would be a channel that silently never starts its orphan
          // grace.
          try {
            handlers.onGone(conn, channel);
          } catch (e) {
            log.error("gone handler threw", { conn: conn.id, channel, err: String(e) });
          }
        }
      },
      error(socket, err) {
        log.warn("socket error", { conn: socket.data?.id, err: String(err) });
      },
    },
  });

  // The panel runs as the same user; nothing else has any business here.
  fs.chmod(path, 0o600);
  log.info("listening", { path });

  return {
    path,
    connFor: (channel) => channels.get(channel),
    conns: () => [...channels.values()],
    stop() {
      for (const conn of channels.values()) conn.close();
      channels.clear();
      server.stop(true);
      // Bind leaves the file behind on exit; do not leave a stale one for the
      // next start to have to probe.
      try {
        if (fs.exists(path)) fs.unlink(path);
      } catch {
        /* already gone */
      }
    },
  };
}
