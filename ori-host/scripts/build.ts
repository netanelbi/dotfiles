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
