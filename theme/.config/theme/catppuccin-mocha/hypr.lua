-- Catppuccin Mocha: Hyprland look. Must equal the defaults in hyprland.lua's
-- hl.config EXACTLY -- this is what `theme-switch catppuccin-mocha` restores live.
-- Every key another theme touches is set here too, or it would leak across.
-- Loaded by theme_apply() in hyprland.lua: base = the machine's own values
-- (gaps_out from machine.lua), rule = hl.window_rule that the next switch undoes.
return function(base, rule)
    hl.config({
        general = {
            gaps_in     = 5,
            gaps_out    = base.gaps_out,
            border_size = 2,
            col = {
                active_border   = { colors = { "rgba(cba6f7ee)", "rgba(89b4faee)" }, angle = 45 },
                inactive_border = "rgba(585b70aa)",
            },
        },
        decoration = {
            rounding = 10,
            blur = { enabled = true },
            shadow = {
                enabled      = true,
                range        = 20,
                render_power = 3,
                sharp        = false,
                offset       = "0 0",
                color        = "rgba(00000080)",
            },
        },
    })
    -- popup/scratchpad borders: hyprland.lua's own rules already are catppuccin.
end
