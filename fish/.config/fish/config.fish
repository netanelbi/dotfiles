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

# Android SDK
set -gx ANDROID_HOME ~/.Android/Sdk
set -gx ANDROID_SDK_ROOT ~/.Android/Sdk
set -gx PATH $ANDROID_SDK_ROOT/platform-tools $ANDROID_SDK_ROOT/cmdline-tools/latest/bin $PATH

# ROCm (AMD GPU)
export HSA_OVERRIDE_GFX_VERSION=11.0.0
export ROCM_PATH=/opt/rocm

# Work aliases
alias appDIR="cd $HOME/Development/mobile-app"
alias devDIR="cd $HOME/Development/devbench"
alias UM="devDIR && $HOME/Development/devbench/venv/bin/python -m devbench.UserManagement"

# Misc aliases
alias nano=micro
alias rspeedtest="ssh root@192.168.1.1 'speedtest'"

# Direnv integration
direnv hook fish | source

