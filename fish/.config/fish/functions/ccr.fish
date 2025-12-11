function ccr --description "Launch Claude Code with custom endpoint and model (wrapper forwards extra args to claude)"
    # Preserve a copy of original arguments (to detect explicit --)
    set -l __orig_argv $argv

    # Parse wrapper flags (known options). argparse will remove recognized flags from $argv.
    argparse --ignore-unknown 'haiku=' 'sonnet=' 'opus=' 'subagent=' 'max-tokens=' 'all=' -- $argv
    or return 1

    # Export fixed base auth / endpoint (preserve existing behavior)
    set -x ANTHROPIC_AUTH_TOKEN "0182d6"
    set -x ANTHROPIC_BASE_URL "https://llm.098742.xyz"
    # set -x ANTHROPIC_BASE_URL "http://localhost:4141"

    # Set default values for each model
    set -l default_haiku "grok-code-fast-1"
    set -l default_sonnet "gpt-5-mini"
    set -l default_opus "claude-sonnet-4.5"
    set -l default_subagent "grok-code-fast-1"

    # If --all provided, override all model envs
    if set -q _flag_all
        set -x ANTHROPIC_DEFAULT_HAIKU_MODEL $_flag_all
        set -x ANTHROPIC_DEFAULT_SONNET_MODEL $_flag_all
        set -x ANTHROPIC_DEFAULT_OPUS_MODEL $_flag_all
        set -x CLAUDE_CODE_SUBAGENT_MODEL $_flag_all
    else
        if set -q _flag_haiku
            set -x ANTHROPIC_DEFAULT_HAIKU_MODEL $_flag_haiku
        else
            set -x ANTHROPIC_DEFAULT_HAIKU_MODEL $default_haiku
        end

        if set -q _flag_sonnet
            set -x ANTHROPIC_DEFAULT_SONNET_MODEL $_flag_sonnet
        else
            set -x ANTHROPIC_DEFAULT_SONNET_MODEL $default_sonnet
        end

        if set -q _flag_opus
            set -x ANTHROPIC_DEFAULT_OPUS_MODEL $_flag_opus
        else
            set -x ANTHROPIC_DEFAULT_OPUS_MODEL $default_opus
        end

        if set -q _flag_subagent
            set -x CLAUDE_CODE_SUBAGENT_MODEL $_flag_subagent
        else
            set -x CLAUDE_CODE_SUBAGENT_MODEL $default_subagent
        end
    end

    # Set max input tokens if provided
    if set -q _flag_max_tokens
        set -x MAX_THINKING_TOKENS $_flag_max_tokens
    end

    # Determine forwarded args:
    # - If original argv contains a literal --, forward only tokens after the first --
    # - Otherwise forward the remaining $argv left after argparse
    set -l forwarded_args

    # Find position of -- in the original args, if any
    set -l idx 1
    set -l found_index 0
    for token in $__orig_argv
        if test "$token" = '--'
            set found_index $idx
            break
        end
        set idx (math $idx + 1)
    end

    if test $found_index -gt 0
        # Collect tokens after the first '--'
        # fish lists are 1-based: tokens after found_index:
        set forwarded_args $__orig_argv[(math $found_index + 1)..-1]  # slice from found_index+1 to end
    else
        # No explicit --: forward leftover $argv produced by argparse
        set forwarded_args $argv
    end

    # Support dry-run mode to print the effective command instead of executing.
    # This is helpful for verifying quoting. Mask auth token for safety in printed output.
    if test -n "$CCR_DRY_RUN"
        # Build printable representation with proper single-quoting of each arg
        set -l printable "command claude --disallowedTools WebSearch"
        for a in $forwarded_args
            # Single-quote arg and escape any single quotes inside it (POSIX style)
            # Replace each ' with '"'"' for safe printing
            set -l escaped (string replace "'" "'\"'\"'" -- $a)
            set printable "$printable '$escaped'"
        end

        # Mask auth token in printed envs
        set -l masked_token "*****"
        printf '%s\n' "DRY-RUN: will run (with ANTHROPIC_AUTH_TOKEN masked):"
        printf '%s\n' "    ANTHROPIC_AUTH_TOKEN=$masked_token ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
        printf '%s\n' "    $printable"
        return 0
    end

    # Execute claude with forwarded args. Use 'command' to avoid recursive function calls named claude.
    command claude --disallowedTools WebSearch $forwarded_args
end