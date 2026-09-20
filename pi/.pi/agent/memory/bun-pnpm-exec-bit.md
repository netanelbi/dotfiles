---
name: bun-pnpm-exec-bit
summary: AUR builds that call pnpm fail with "Permission denied"/Error 126 when ~/.bun/bin/pnpm's target pnpm.mjs has lost its exec bit; chmod +x fixes it
pinned: true
created: 2026-09-15
modified: 2026-09-15
---
~/.bun/bin/pnpm is a symlink to ~/.bun/install/global/node_modules/pnpm/bin/pnpm.mjs. A bun global install (seen 2026-09-08) left that .mjs as -rw-r--r--, so every invocation dies with "bash: permission denied" and CMake targets report Error 126. Hit while building stable-diffusion.cpp-vulkan-git from the AUR (its server frontend runs pnpm by absolute path, and ~/.bun/bin comes first in PATH so CMake picks the broken shim over /usr/bin/pnpm).

Fix: chmod +x ~/.bun/install/global/node_modules/pnpm/bin/pnpm.mjs — then ~/.bun/bin/pnpm --version works (reported 12.3.4; system pnpm is 11.26.0).

Check it before blaming a PKGBUILD for a build failure in anything that runs pnpm/pnpx: ls -l ~/.bun/install/global/node_modules/pnpm/bin/
