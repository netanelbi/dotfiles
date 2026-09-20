---
name: pacman-sc-download-dirs
summary: pacman -Sc errors ("could not open file download-XXXXX") on empty alpm:alpm temp dirs left by killed pacman runs; rm -rf them first
pinned: true
created: 2026-09-14
modified: 2026-09-14
---
/var/cache/pacman/pkg accumulates empty `download-XXXXXX` dirs (owner alpm:alpm, mode 700, 0 bytes) from killed/interrupted pacman runs. They date back months, so they are not from one bad install.

pacman -Sc treats each as a cache entry to delete, fails to read it as a file, and prints `error: could not open file .../download-XXXXXX: Error reading fd 8` for every one — 167 of them on 2026-09-14. They hold no space, so removing them is cosmetic tidiness, not a cleanup: `pkexec rm -rf /var/cache/pacman/pkg/download-*`.

Also note pacman -Sc prompt semantics, easy to get backwards:
- "remove all other packages from cache?" Y = delete packages not installed (the usual safe win, re-downloadable).
- second prompt "remove unused repositories?" Y = drops sync dbs for repos not in pacman.conf.
`--noconfirm` answers Y to both, so run it interactively when the second prompt matters.

2026-09-14: cache 15G/4369 files -> 5.3G, freed ~9GB (1371 cached packages were no longer installed). Disk 755G -> 746G on nvme0n1p2.
