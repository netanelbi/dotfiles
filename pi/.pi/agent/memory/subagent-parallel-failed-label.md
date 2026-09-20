---
name: subagent-parallel-failed-label
summary: Parallel subagent rollup mislabels children that outlive the 2s grace as "failed" though they ran fine
pinned: true
created: 2026-09-10
modified: 2026-09-10
---
In ~/Development/Personal/my-pi/extensions/subagent/index.ts: parallel dispatch awaits runSingleAgent, but AGENT_GRACE_MS = 2000 (line 349) detaches any child still running at 2s and resolves it with exitCode -1. isFailedResult counts exitCode !== 0 as failed, so the rollup reports "Parallel: 0/3 succeeded" for children that actually finished fine seconds later; their real answers arrive as late [SUBAGENT_DONE] messages after the turn. Children were healthy (registry status done, exit 0). Fix candidate: in the parallel summaries treat exitCode === -1 as "running/detached", not failed. Verified live 2026-09-10 with three parallel sanity agents (ollama glm-5.3-flash, ~4s each).
