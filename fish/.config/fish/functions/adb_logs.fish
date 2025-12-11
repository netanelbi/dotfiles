function adb_logs --description 'Fish port of adb_logs helper for filtering adb logcat output'
    argparse 'c/clear' 'p/process=' 't/tag=+' 'm/match=+' 'text=+' 'S/serial=' 'usb' 'emulator' 'no-gocat' 'h/help' -- $argv
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
            '  -S, --serial <device-id>  Run against a specific device/emulator.' \
            '      --usb                 Shortcut for "adb -d" (USB device).' \
            '      --emulator            Shortcut for "adb -e" (emulator).' \
            '      --no-gocat            Do not pipe output through gocat.' \
            '  -h, --help                Show this help message.' \
            '' \
            'Additional arguments are passed straight to "adb logcat".'
        return 0
    end

    set -l package $_flag_process
    set -l tags
    if set -q _flag_tag
        set tags $_flag_tag
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

    if test (count $tags) -gt 0
        set cmd $cmd -s $tags
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

    if test $use_gocat -eq 1
        if test (count $filter_cmd) -gt 0
            $cmd | gocat | $filter_cmd
        else
            $cmd | gocat
        end
    else if test (count $filter_cmd) -gt 0
        $cmd | $filter_cmd
    else
        $cmd
    end
end
