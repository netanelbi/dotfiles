/**
 * One binary: `dist/ori-host`.
 *
 * The two `autoload*: false` flags are not tidiness. A compiled Bun binary
 * otherwise reads `.env` and `bunfig.toml` FROM ITS WORKING DIRECTORY at
 * startup -- and this one is started by systemd from whatever directory the
 * unit happened to land in, and spawns pi children in ~/.dotfiles. A stray
 * `.env` in either would silently reconfigure the daemon.
 *
 * `--smol` is baked in through `execArgv` because there is no wrapper script to
 * pass it on the command line: the host holds several conversations' worth of
 * turns and is otherwise idle, so the smaller heap is the right trade.
 *
 * `bytecode` moves parsing to build time (faster cold start), and `sourcemap:
 * "linked"` keeps stack traces in the journal readable without inflating the
 * binary.
 */

import { join } from "node:path";
import { homedir } from "node:os";
import { renameSync, rmSync, chmodSync } from "node:fs";

const root = join(import.meta.dir, "..");
const outfile = join(root, "dist", "ori-host");

const result = await Bun.build({
  entrypoints: [join(root, "src", "main.ts")],
  compile: {
    target: "bun-linux-x64",
    outfile,
    execArgv: ["--smol"],
    autoloadDotenv: false,
    autoloadBunfig: false,
  },
  minify: true,
  bytecode: true,
  sourcemap: "linked",
});

if (!result.success) {
  for (const message of result.logs) console.error(message);
  process.exit(1);
}

const size = Bun.file(outfile).size;
console.log(`built ${outfile} (${(size / 1024 / 1024).toFixed(1)} MB)`);

// Install. The systemd unit execs ~/.local/bin/ori-host, NOT dist/ — a build
// that stops at dist/ leaves the service running a stale binary until someone
// remembers to copy by hand (which has already bitten once).
const installed = join(homedir(), ".local", "bin", "ori-host");
// ETXTBSY if the old binary is running (the host always is) — write beside it
// and rename over it, which the kernel allows.
const staging = installed + ".new";
rmSync(staging, { force: true });
await Bun.write(staging, Bun.file(outfile));
renameSync(staging, installed);
chmodSync(installed, 0o755); // Bun.write/rename leave 644 — a non-executable
// install crashes the service with exec status 126 (has bitten once).
console.log(`installed ${installed}`);
