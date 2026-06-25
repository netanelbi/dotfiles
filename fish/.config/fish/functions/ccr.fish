function ccr --description "Launch Claude Code against ollama-shim (systemd, localhost:11435) -> Ollama Cloud, with model mapping + 1M context"
    # Thin wrapper: the ollama-shim proxy is managed by systemd (ollama-shim.service),
    # so ccr only wires env vars and forwards to claude. No process management here.
    argparse --ignore-unknown 'haiku=' 'sonnet=' 'opus=' 'subagent=' 'max-tokens=' 'all=' 'base-url=' -- $argv
    or return 1

    # --- Endpoint: ollama-shim on localhost (or --base-url to bypass it) ---
    if set -q _flag_base_url
        set -x ANTHROPIC_BASE_URL $_flag_base_url
    else
        set -l proxy_port (set -q CCR_PROXY_PORT; and echo $CCR_PROXY_PORT; or echo 11435)
        set -x ANTHROPIC_BASE_URL "http://localhost:$proxy_port"
    end

    # --- Auth: OLLAMA_API_KEY (set in secrets.fish) ---
    if set -q OLLAMA_API_KEY
        set -x ANTHROPIC_AUTH_TOKEN $OLLAMA_API_KEY
    else if set -q CCR_AUTH_TOKEN
        set -x ANTHROPIC_AUTH_TOKEN $CCR_AUTH_TOKEN
    else
        echo "ccr: OLLAMA_API_KEY not set - define it in ~/.config/fish/conf.d/secrets.fish" >&2
        return 1
    end

    # --- Model mapping: Claude Code tiers -> Ollama Cloud models ---
    # opus (main) -> glm-5.2[1m]  (1M context window by default; drop [1m] for default context)
    # sonnet      -> deepseek-v4-pro
    # haiku       -> deepseek-v4-flash
    # subagents   -> deepseek-v4-flash
    if set -q _flag_all
        set -x ANTHROPIC_DEFAULT_HAIKU_MODEL   $_flag_all
        set -x ANTHROPIC_DEFAULT_SONNET_MODEL $_flag_all
        set -x ANTHROPIC_DEFAULT_OPUS_MODEL   $_flag_all
        set -x CLAUDE_CODE_SUBAGENT_MODEL     $_flag_all
    else
        set -x ANTHROPIC_DEFAULT_HAIKU_MODEL   (set -q _flag_haiku;    and echo $_flag_haiku;    or echo "deepseek-v4-flash")
        set -x ANTHROPIC_DEFAULT_SONNET_MODEL  (set -q _flag_sonnet;  and echo $_flag_sonnet;  or echo "deepseek-v4-pro")
        set -x ANTHROPIC_DEFAULT_OPUS_MODEL    (set -q _flag_opus;    and echo $_flag_opus;    or echo "glm-5.2[1m]")
        set -x CLAUDE_CODE_SUBAGENT_MODEL      (set -q _flag_subagent; and echo $_flag_subagent; or echo "deepseek-v4-flash")
    end

    if set -q _flag_max_tokens
        set -x MAX_THINKING_TOKENS $_flag_max_tokens
    end

    # --- Forward remaining args to claude (tokens after a literal --, else leftover argv) ---
    set -l forwarded_args
    set -l idx 1; set -l found_index 0
    for token in $argv
        if test "$token" = '--'
            set found_index $idx; break
        end
        set idx (math $idx + 1)
    end
    if test $found_index -gt 0
        set forwarded_args $argv[(math $found_index + 1)..-1]
    else
        set forwarded_args $argv
    end

    # --- Dry-run ---
    if test -n "$CCR_DRY_RUN"
        printf '%s\n' "DRY-RUN (token masked):"
        printf '%s\n' "    ANTHROPIC_AUTH_TOKEN=***** ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
        printf '%s\n' "    HAIKU=$ANTHROPIC_DEFAULT_HAIKU_MODEL SONNET=$ANTHROPIC_DEFAULT_SONNET_MODEL OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL SUBAGENT=$CLAUDE_CODE_SUBAGENT_MODEL"
        printf '%s\n' "    claude --allow-dangerously-skip-permissions $forwarded_args"
        return 0
    end

    command claude --allow-dangerously-skip-permissions $forwarded_args
end