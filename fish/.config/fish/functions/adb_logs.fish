function adb_logs --description 'Fish port of adb_logs helper for filtering adb logcat output'
    argparse 'c/clear' 'p/process=' 't/tag=+' 'm/match=+' 'text=+' 'l/level=' 'S/serial=' 'usb' 'emulator' 'no-gocat' 'no-strip' 'h/help' -- $argv
    or return 1

    if set -q _flag_help
        printf '%s\n' \
            'Usage: adb_logs [options] [logcat args...]' \
            '' \
            'Options:' \
            '  -c, --clear                Clear existing log buffers before streaming.' \
            '  -p, --process <package>   Filter by the PID(s) of the given package name.' \
            '  -t, --tag <tag[:level]>   Add a tag filter (repeatable).' \
            '  -m, --match <pattern>     Filter output by text/regex (repeatable).' \
            '      --text <pattern>      Same as --match (alias).' \
            '  -l, --level <V|D|I|W|E|F> Minimum log level (default: V for all).' \
            '  -S, --serial <device-id>  Run against a specific device/emulator.' \
            '      --usb                 Shortcut for "adb -d" (USB device).' \
            '      --emulator            Shortcut for "adb -e" (emulator).' \
            '      --no-gocat            Do not pipe output through gocat.' \
            '      --no-strip            Do not strip Capacitor log format (keep full output).' \
            '  -h, --help                Show this help message.' \
            '' \
            'Additional arguments are passed straight to "adb logcat".'
        return 0
    end

    set -l package $_flag_process

    # Parse and validate level
    set -l min_level
    if set -q _flag_level
        set min_level (string upper $_flag_level)
        if not string match -qr '^[VDIWEFS]$' $min_level
            printf 'adb_logs: invalid level "%s". Use V, D, I, W, E, F, or S.\n' $_flag_level >&2
            return 1
        end
    end

    # Build tag filters - apply min_level to tags without explicit level
    set -l tags
    if set -q _flag_tag
        for tag in $_flag_tag
            if string match -qr ':' $tag
                # Tag has explicit level, keep as-is
                set tags $tags $tag
            else if test -n "$min_level"
                # Apply min_level to tag without explicit level
                set tags $tags "$tag:$min_level"
            else
                # No level specified, keep tag as-is (defaults to V)
                set tags $tags $tag
            end
        end
    end

    set -l matches
    if set -q _flag_match
        set matches $matches $_flag_match
    end
    if set -q _flag_text
        set matches $matches $_flag_text
    end

    set -l adb_args
    if set -q _flag_serial
        set adb_args $adb_args -s $_flag_serial
    end
    if set -q _flag_usb
        set adb_args $adb_args -d
    end
    if set -q _flag_emulator
        set adb_args $adb_args -e
    end

    set -l logcat_args $argv
    set -l clear_logs 0
    if set -q _flag_clear
        set clear_logs 1
    end

    set -l strip_capacitor 1
    if set -q _flag_no_strip
        set strip_capacitor 0
    end

    set -l cmd adb
    if test (count $adb_args) -gt 0
        set cmd $cmd $adb_args
    end
    set cmd $cmd logcat

    if test $clear_logs -eq 1
        if not adb $adb_args logcat -c
            return $status
        end
    end

    if test -n "$package"
        set -l pids (adb $adb_args shell pidof $package 2>/dev/null)
        if not set -q pids[1]
            printf 'adb_logs: process "%s" not found on device.\n' $package >&2
            return 1
        end
        for pid in $pids
            set cmd $cmd --pid=$pid
        end
    end

    # Apply tag/level filters
    if test (count $tags) -gt 0
        # Tags specified - use -s for exclusive filtering
        set cmd $cmd -s $tags
    else if test -n "$min_level"
        # Only level specified - filter all tags at this level (no -s)
        set cmd $cmd "*:$min_level"
    end

    if test (count $logcat_args) -gt 0
        set cmd $cmd $logcat_args
    end

    set -l use_gocat 1
    if set -q _flag_no_gocat
        set use_gocat 0
    else if not type -q gocat
        set use_gocat 0
    end

    set -l filter_cmd
    if test (count $matches) -gt 0
        if type -q rg
            set filter_cmd rg --color=always
            for pattern in $matches
                set filter_cmd $filter_cmd -e $pattern
            end
        else
            set -l joined (string join '|' $matches)
            set filter_cmd grep --color=always -E $joined
        end
    end

    # Build sed commands for post-processing
    # Strip Capacitor log format: "File: <url> - Line <num> - Msg: " -> ""
    # Keeps gocat's tag/level prefix, just removes the verbose File/Line/Msg part
    set -l strip_sed
    if test $strip_capacitor -eq 1
        set strip_sed sed -u -E 's/File: [^ ]+ - Line [0-9]+ - Msg: //'
    end

    if test $use_gocat -eq 1
        # Gocat can't parse tags with spaces in brackets like "Tag[Foo Bar]"
        # Pipe through sed to replace spaces with underscores inside [...]
        set -l gocat_sed sed -u 's/\(\[[^]]*\) \([^]]*\]\)/\1_\2/g'
        # Strip must happen AFTER gocat so gocat can parse the logcat format
        if test (count $strip_sed) -gt 0
            if test (count $filter_cmd) -gt 0
                $cmd | $gocat_sed | gocat | $strip_sed | $filter_cmd
            else
                $cmd | $gocat_sed | gocat | $strip_sed
            end
        else
            if test (count $filter_cmd) -gt 0
                $cmd | $gocat_sed | gocat | $filter_cmd
            else
                $cmd | $gocat_sed | gocat
            end
        end
    else if test (count $strip_sed) -gt 0
        if test (count $filter_cmd) -gt 0
            $cmd | $strip_sed | $filter_cmd
        else
            $cmd | $strip_sed
        end
    else if test (count $filter_cmd) -gt 0
        $cmd | $filter_cmd
    else
        $cmd
    end
end
