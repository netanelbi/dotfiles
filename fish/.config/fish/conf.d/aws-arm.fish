function __aws_duration_to_seconds --argument-names dur
    set -l matches (string match -r '^([0-9]+(?:\.[0-9]+)?)([smhd]?)$' -- $dur)
    test (count $matches) -ne 3; and return 1
    set -l num $matches[2]
    set -l unit $matches[3]
    test -z "$unit"; and set unit s
    switch $unit
        case s; echo $num | awk '{printf "%d\n", $1}'
        case m; echo $num | awk '{printf "%d\n", $1*60}'
        case h; echo $num | awk '{printf "%d\n", $1*3600}'
        case d; echo $num | awk '{printf "%d\n", $1*86400}'
    end
end

function __aws_fmt_duration --argument-names s
    set -l h (math -s0 "$s / 3600")
    set -l m (math -s0 "($s % 3600) / 60")
    set -l sec (math "$s % 60")
    set -l parts
    if test $h -gt 0
        set -a parts "$h"h "$m"m
    else if test $m -gt 0
        set -a parts "$m"m
    end
    set -a parts "$sec"s
    string join " " $parts
end

function __aws_cancel_timer --description "Internal: cancel pending AWS auto-disarm timer"
    if test -f ~/.aws/.disarm.pid
        set -l pid (cat ~/.aws/.disarm.pid 2>/dev/null)
        if test -n "$pid"
            kill $pid 2>/dev/null
        end
    end
    rm -f ~/.aws/.disarm.pid ~/.aws/.disarm.expires
end

function aws-arm --description "Arm AWS creds (prd|stg) with auto-disarm timer (default 30m)"
    set -l env $argv[1]
    set -l ttl $argv[2]
    test -z "$ttl"; and set ttl 30m

    if not contains -- $env prd stg
        echo "Usage: aws-arm prd|stg [duration, e.g. 30m, 1h, 90m]" >&2
        return 1
    end

    if not test -f ~/.aws/credentials.$env
        echo "Missing ~/.aws/credentials.$env" >&2
        return 1
    end

    set -l secs (__aws_duration_to_seconds $ttl)
    if test -z "$secs"; or test "$secs" -le 0
        echo "Invalid duration: $ttl (use e.g. 30s, 30m, 1h, 1d)" >&2
        return 1
    end

    __aws_cancel_timer

    ln -sf ~/.aws/credentials.$env ~/.aws/credentials

    fish -c "sleep $ttl; and rm -f ~/.aws/credentials ~/.aws/.disarm.pid ~/.aws/.disarm.expires" &
    set -l pid $last_pid
    disown $pid

    echo $pid > ~/.aws/.disarm.pid
    math (date +%s) + $secs > ~/.aws/.disarm.expires

    echo "Armed: $env (auto-disarm in "(__aws_fmt_duration $secs)", pid $pid)"
end

function aws-off --description "Disarm AWS creds and cancel any pending auto-disarm timer"
    rm -f ~/.aws/credentials
    __aws_cancel_timer
    echo "Disarmed."
end

function aws-status --description "Show current AWS arm state and time remaining"
    if test -L ~/.aws/credentials
        set -l target (readlink ~/.aws/credentials)
        echo "Armed → $target"
        if test -f ~/.aws/.disarm.expires
            set -l now (date +%s)
            set -l exp (cat ~/.aws/.disarm.expires)
            set -l left (math $exp - $now)
            if test $left -gt 0
                set -l pid_running 0
                if test -f ~/.aws/.disarm.pid
                    set -l pid (cat ~/.aws/.disarm.pid)
                    if kill -0 $pid 2>/dev/null
                        set pid_running 1
                    end
                end
                if test $pid_running -eq 1
                    echo "Auto-disarm in "(__aws_fmt_duration $left)
                else
                    echo "Auto-disarm in "(__aws_fmt_duration $left)" (timer process not running — will not auto-disarm)"
                end
            else
                echo "Timer expired but symlink still present (run aws-off)"
            end
        else
            echo "No auto-disarm timer set"
        end
    else if test -e ~/.aws/credentials
        echo "Armed (regular file, not a symlink) → ~/.aws/credentials"
    else
        echo "Disarmed."
    end
end
