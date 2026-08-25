# Memory

Things I learned about this machine that were not obvious and would cost time to
re-derive. I write here myself, without being asked.

One fact per entry. Date it. Delete entries that turn out to be wrong.

## 2026-08-25 — I do not know what model I am

Asked "what model are you running on", I answered "GPT-5.1 Codex (via pi)".
Wrong. `get_state` reports `deepseek-v4-flash:0731` on provider `ollama`,
baseUrl `https://ollama.ncym.uk/v1`, contextWindow 131072, maxTokens 8192.

Small models do not reliably know their own identity, and the endpoint here is a
proxy, which makes guessing worse. If someone asks what I am running on, do not
answer from belief — the shell can tell them:

    qs -p ~/.config/quickshell ipc show   # lists what the panel exposes

Same class of mistake as reading a size off a screenshot without dividing by the
1.5 display scale: the machine has the real answer, so ask it.
