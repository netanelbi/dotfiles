# FZF configuration for interactive file/content search mid-command
# Allows Ctrl+F to insert file paths into command line

# File search with Ctrl+F - inserts selected file path at cursor
function fzf_file_picker
    fd --type f --hidden --exclude .git . | \
    fzf --multi --preview 'head -200 {}' \
        --bind 'ctrl-p:preview-page-up' \
        --bind 'ctrl-n:preview-page-down' \
        --header 'Ctrl+P/N for preview | Enter to select | Tab for multi-select' | \
    tr '\n' ' '
end

# Directory search with Ctrl+D - inserts selected directory path
function fzf_dir_picker
    fd --type d --hidden --exclude .git . | \
    fzf --preview 'ls -la {}' \
        --bind 'ctrl-p:preview-page-up' \
        --bind 'ctrl-n:preview-page-down' \
        --header 'Ctrl+P/N for preview | Enter to select' | \
    tr '\n' ' '
end

# Content search with Ctrl+G - searches file contents with ripgrep
function fzf_content_picker
    rg --files-with-matches --hidden --color never . | \
    fzf --preview 'rg -C3 --color always ""' \
        --bind 'ctrl-p:preview-page-up' \
        --bind 'ctrl-n:preview-page-down' \
        --header 'Select file containing search term'
end

# Keybindings for mid-command usage
bind \cf 'commandline -i (fzf_file_picker)'  # Ctrl+F for files
bind \eg 'commandline -i (fzf_dir_picker)'   # Alt+G for directories

# Alternative keybindings if conflicts occur
# bind \e\cf 'commandline -i (fzf_file_picker)'  # Ctrl+Alt+F for files
# bind \e\cg 'commandline -i (fzf_content_picker)'  # Ctrl+Alt+G for content
