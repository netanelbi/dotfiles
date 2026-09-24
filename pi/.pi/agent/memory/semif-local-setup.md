---
name: semif-local-setup
summary: SemIf: ~/Development/Personal/semif, uv python 3.13 + llama-cpp-python CPU, 96 tok/s prefill
pinned: true
created: 2026-09-23
modified: 2026-09-23
---
SemIf (github.com/TheoLeeCJ/SemIf) cloned to ~/Development/Personal/semif, models/Qwen_Qwen3.5-4B-Q4_K_M.gguf (3.01 GB, sha256 13c16f42...).

Env: `uv venv --python 3.13 .venv`, `uv pip install torch==2.10.0 --index-url https://download.pytorch.org/whl/cpu`, `uv pip install -e '.[test]'`, `uv pip install llama-cpp-python==0.3.35` (exact pins: torch 2.10.0+cpu, transformers 5.17.0, numpy 2.2.6).

WHY uv: the system python is 3.14 only and SemIf's pinned numpy 2.2.6 has no cp314 wheel — pip builds it from sdist and gcc 16 rejects `attribute target evex512`. Any project here pinning pre-2026 deps needs `uv venv --python 3.13`.

Run:
semif-score --mode direct --backend llamacpp --gguf models/Qwen_Qwen3.5-4B-Q4_K_M.gguf --llama-threads 12 --model Qwen/Qwen3.5-4B --revision 851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a --input <file.jsonl> --output <new.jsonl>
(--output must not already exist; modes direct|serial|shared)

The backend is raw ctypes into llama-cpp-python's bundled libllama (llama_get_logits_ith) — no torch forward pass. The system llama.cpp 0.4.1 also loads this GGUF (arch qwen35).

Measured 2026-09-23, CPU only, 12 threads, Radeon 890M unused:
- examples/decisions.jsonl: works, p=0.9996 on the owned support-1 row
- benchmarks/data/authored144.jsonl: coverage 1.0, mean_family_balanced_accuracy 0.80
- median forward 1.54 s, median prompt 147 tokens, 96 tok/s prefill, 144 rows = 222 s
- evaluate: python benchmarks/evaluate.py --gold <data.jsonl> --predictions <results.jsonl> --output <new.json>

flm (the NPU route) is dead until the firmware/module drift is fixed: FW 1.0.0.63 + amdxdna 0.1 rejected by flm 1.0.6, every request aborts (ERT_CMD_STATE_NEW).
