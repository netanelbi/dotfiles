function bonsai --description 'Local Bonsai 2 27B server (NPU prefill + iGPU decode + DFlash) with a live stats monitor'
    # bonsai [code|math|chat] [--vulkan-only] [--no-vision] [--single] [--ctx N]  (default: 3 cached sessions sharing the pi prefix, 64k ctx; --single: 1 session, 128k, pin still loads)   start server on :8091 (background) + open the monitor
    # bonsai top | stop | status | log | pin | unpin     monitor / stop / is it up / tail log / pin or unpin the system prompt
    set -l root ~/Development/Personal/npu-spec-sweep
    set -l dir ~/.cache/bonsai
    set -l port 8091
    mkdir -p $dir
    set -l pidf $dir/server.pid
    set -l logf $dir/server.log

    set -l pid ''
    if test -f $pidf; and kill -0 (cat $pidf) 2>/dev/null
        set pid (cat $pidf)
    end

    switch "$argv[1]"
        case stop
            if test -n "$pid"
                kill $pid; and echo "bonsai: stopped (pid $pid)"
                rm -f $pidf
            else
                echo "bonsai: not running"
            end
            return
        case status
            if test -n "$pid"; and curl -sf http://127.0.0.1:$port/health >/dev/null
                echo "bonsai: up on :$port (pid $pid)"
            else if test -n "$pid"
                echo "bonsai: starting (pid $pid)"
            else
                echo "bonsai: not running"
            end
            return
        case pin
            # pin the shared system prompt (everything before the first user message) of the session in slot 0:
            # the earliest saved branch-point state marks that boundary. Loads at every server start from disk.
            set -l n (curl -sf http://127.0.0.1:$port/cache/stats | python3 -c "import sys,json; d=json.load(sys.stdin); s=[x['n'] for x in d.get('snapshots',[])]; print(min(s) if s else '')")
            if test -z "$n"
                echo "bonsai: nothing to pin yet (send one request first)"
                return 1
            end
            # one pin at a time: drop older pins (server + files) before pinning the new one
            for id in (curl -sf http://127.0.0.1:$port/cache/stats | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin).get('snapshots',[]) if s.get('pinned')]")
                curl -sf -m 30 -X POST http://127.0.0.1:$port/cache/pin -H 'Content-Type: application/json' -d "{\"unpin\":$id}" >/dev/null
            end
            for f in ~/.cache/bonsai/kvtree/pinned/*.kvt; rm -f $f; end
            curl -sf -m 120 -X POST http://127.0.0.1:$port/cache/pin -H 'Content-Type: application/json' -d "{\"id_slot\":0,\"n_tokens\":$n}" >/dev/null
            and echo "bonsai: pinned the first $n tokens (system prompt), replacing any older pin; reused by new sessions and after restarts"
            return
        case unpin
            # drop every pin: in the running server (if up) and the files that load at start
            if curl -sf http://127.0.0.1:$port/health >/dev/null
                for id in (curl -sf http://127.0.0.1:$port/cache/stats | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin).get('snapshots',[]) if s.get('pinned')]")
                    curl -sf -m 30 -X POST http://127.0.0.1:$port/cache/pin -H 'Content-Type: application/json' -d "{\"unpin\":$id}" >/dev/null
                end
            end
            for f in ~/.cache/bonsai/kvtree/pinned/*.kvt; rm -f $f; end
            echo "bonsai: unpinned (no pin loads at next start)"
            return
        case log
            tail -f $logf
            return
        case top
            if test -z "$pid"
                echo "bonsai: not running (start with: bonsai [code|math|chat])"
                return 1
            end
            $root/tools/bonsai_top.py $logf $port $pid
            return
    end

    if test -n "$pid"
        echo "bonsai: already running (pid $pid), opening monitor. 'bonsai stop' to restart with other options."
        $root/tools/bonsai_top.py $logf $port $pid
        return
    end

    set -l task code
    set -l extra
    set -l vision --vision
    set -l kvtree 1
    set -l np 3
    set -l ctx
    set -l i 1
    while test $i -le (count $argv)
        switch $argv[$i]
            case code math chat
                set task $argv[$i]
            case --vulkan-only
                set -a extra --vulkan-only
            case --no-vision
                set vision
            case --single
                set np 1
            case --ctx
                set i (math $i + 1)
                set ctx $argv[$i]
            case '*'
                echo "bonsai: unknown option $argv[$i]"
                return 2
        end
        set i (math $i + 1)
    end

    # the NPU path must not share the accelerators with a benchmark: refuse if another llama-server is up
    if pgrep -x llama-server >/dev/null
        echo "bonsai: another llama-server is running; stop it first"
        return 1
    end

    echo "bonsai: starting ($task $extra) on :$port, log $logf"
    if test -n "$ctx"
        env CTX=$ctx KVTREE=$kvtree NP=$np nohup $root/run-best.sh $task $extra $vision --port $port --alias bonsai-27b >$logf 2>&1 &
    else
        env KVTREE=$kvtree NP=$np nohup $root/run-best.sh $task $extra $vision --port $port --alias bonsai-27b >$logf 2>&1 &
    end
    set -l spid $last_pid
    echo $spid >$pidf
    disown $spid 2>/dev/null
    for n in (seq 1 180)
        if curl -sf http://127.0.0.1:$port/health >/dev/null
            break
        end
        if not kill -0 $spid 2>/dev/null
            echo "bonsai: server died, last log lines:"
            tail -15 $logf
            rm -f $pidf
            return 1
        end
        sleep 1
    end
    echo "bonsai: ready. pi model: bonsai/bonsai-27b. Monitor: q quits the monitor only; 'bonsai stop' stops the server."
    $root/tools/bonsai_top.py $logf $port $spid
end
