# Beads: always use the systemd-managed shared Dolt server (beads-dolt.service on 127.0.0.1:3308).
#
# BEADS_DOLT_SHARED_SERVER=1 : all repos share ~/.beads/shared-server (one DB per repo) instead
#                              of spinning up a per-project Dolt server.
# BEADS_DOLT_AUTO_START=0    : never let bd spawn its OWN Dolt server — the systemd unit owns it.
#                              Without this, plain `bd init` tries to start a server on top of the
#                              systemd one, conflicts, and leaves the per-repo DB half-created
#                              ("Setup incomplete: No dolt database found"). With it, `bd init`
#                              just connects and creates the repo DB lazily on first write.
#
# Net effect: starting beads in any new folder is just `git init && bd init` — zero flags.
set -gx BEADS_DOLT_SHARED_SERVER 1
set -gx BEADS_DOLT_AUTO_START 0
