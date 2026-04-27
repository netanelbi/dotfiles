function tmp --description 'Create /tmp/<name> and launch claude there'
    if test (count $argv) -eq 0
        echo "usage: tmp <name>" >&2
        return 1
    end
    set -l dir /tmp/(string join '-' $argv)
    mkdir -p $dir
    cd $dir
    claude
end
