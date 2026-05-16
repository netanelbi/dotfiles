function tmp --description 'Create /tmp/<name> and launch claude there'
    if test (count $argv) -eq 0
        echo "usage: tmp <name> [claude args...]" >&2
        return 1
    end
    set -l dir /tmp/$argv[1]
    mkdir -p $dir
    cd $dir
    claude $argv[2..]
end
