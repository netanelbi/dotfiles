---
name: whisper-npu
summary: whisper-npu (~/Development/Personal/whisper-npu): encoder on the XDNA2 NPU, decoder on CPU; English PTT is Moonshine v2 on CPU
pinned: true
created: 2026-09-09
modified: 2026-09-09
---
whisper-npu: ~/Development/Personal/whisper-npu, Rust workspace, sibling to kokoro-npu. Encoder linears on XDNA2 NPU; decoder CPU. Keep-alive daemons per model tag (unix socket, 5-min idle); 16 hw contexts — whisper 4 each, kokoro 8. English PTT = Moonshine v2 (tiny/small/medium), CPU ONLY, medium 5.5% WER / ~0.5s warm. `ptt` script + voice capsule use moonshine-v2-medium --no-daemon. README.md is accurate.
