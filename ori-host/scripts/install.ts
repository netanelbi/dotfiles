/**
 * Build the host and put the binary where the unit expects it.
 *
 * `ori-agent.service` runs `%h/.local/bin/ori-host`, and until now nothing put
 * anything there: the binary is ~80 MB with `bun build --compile`, so it cannot
 * live in the repo and stow cannot symlink it into place like every other script
 * in this dotfiles tree. It is built per machine instead, and this is the step
 * that does it.
 *
 * It deliberately runs NO systemctl. Enabling a unit and restarting a daemon the
 * user may be talking to right now are decisions that belong to the user, not to
 * a build script -- so the commands are printed and not executed.
 *
 * Written over a RENAME rather than in place. The target may be the running
 * host, and writing into a live executable's inode is ETXTBSY; a rename swaps
 * the directory entry and leaves the running process on its own inode until it
 * is restarted.
 */

import { chmodSync, copyFileSync, mkdirSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";

const dryRun = process.argv.includes("--dry-run") || process.argv.includes("-n");

const home = Bun.env["HOME"];
if (!home) {
  console.error("HOME is unset; refusing to guess where to install");
  process.exit(1);
}

const root = join(import.meta.dir, "..");
const built = join(root, "dist", "ori-host");
const target = join(home, ".local", "bin", "ori-host");

console.log(`target: ${target}`);
if (dryRun) {
  console.log(`source: ${built} (would be built by scripts/build.ts)`);
  console.log("--dry-run: nothing built, nothing written");
  process.exit(0);
}

// Runs scripts/build.ts in this process. It exits non-zero itself on a failed
// build, so there is nothing to check here.
await import("./build.ts");

mkdirSync(dirname(target), { recursive: true });
const staged = `${target}.new`;
copyFileSync(built, staged);
chmodSync(staged, 0o755);
renameSync(staged, target);

const mb = (Bun.file(target).size / 1024 / 1024).toFixed(1);
console.log(`installed ${mb} MB -> ${target}`);
console.log(
  `
Not run for you -- these are yours to run:

  stow scripts                                    # once, for the unit file
  systemctl --user daemon-reload
  systemctl --user disable --now ori-agent.socket # socket activation is GONE
  systemctl --user enable --now ori-agent.service

  journalctl --user -u ori-agent -f -o cat | jq   # the host logs NDJSON

Upgrading later is this script again, then:

  systemctl --user restart ori-agent
`.trim(),
);
