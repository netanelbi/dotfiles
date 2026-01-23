source /usr/share/cachyos-fish-config/cachyos-config.fish

# Starship prompt
source (/usr/bin/starship init fish --print-full-init | psub)

# Zoxide
zoxide init fish | source

# Package management aliases
alias i="paru -S"
alias u="paru -Rnsc"
alias si="paru"
alias ss="paru -Ss"

# AI chat helpers
alias ?c="aichat -e"

function ?
    set prompt $argv
    if isatty stdin
        aichat $prompt
    else
        begin
            cat
            if test (count $argv) -gt 0
                echo ""
                echo "User prompt: $prompt"
            end
        end | aichat
    end
end

function ??
    set prompt $argv
    begin
        wl-paste
        echo ""
        echo "User prompt: $prompt"
    end | aichat
end

# User paths
fish_add_path ~/.local/bin
fish_add_path ~/.bun/bin
fish_add_path ~/.opencode/bin

# Android SDK
set -gx ANDROID_HOME ~/.Android/Sdk
set -gx ANDROID_SDK_ROOT ~/.Android/Sdk
fish_add_path $ANDROID_SDK_ROOT/platform-tools
fish_add_path $ANDROID_SDK_ROOT/cmdline-tools/latest/bin


# Work aliases
alias ccropAPP="cd /home/netanel/Development/CCrop/c-crop-app"
alias ccropDEV="cd /home/netanel/Development/CCrop/cCropDev"
alias UM="ccropDEV && /home/netanel/Development/CCrop/cCropDev/.venv/bin/python -m CCrop.UserManagement"

# Misc aliases
alias nano=micro
alias rspeedtest="ssh root@192.168.1.1 'speedtest'"

# Direnv integration
direnv hook fish | source

