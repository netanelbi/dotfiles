-- Neo-Brutal Dark: Hyprland look. Cream borders, lavender hard shadow (slick-b), square corners, a sharp offset shadow.
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule)
    hl.config({
        general = {
            gaps_in     = 11,  -- window gap 22 = the mockup's --gap
            gaps_out    = 22,
            border_size = 3,
            col = {
                active_border   = "rgb(EDE8DF)",
                inactive_border = "rgb(6B6878)",
            },
        },
        decoration = {
            rounding = 0,
            blur = { enabled = false },
            shadow = {
                enabled      = true,
                range        = 0,
                render_power = 1,
                sharp        = true,
                offset       = "5 5",
                color        = "rgb(C9B8FF)",
            },
        },
    })
    -- The popups and the scratchpad hardcode catppuccin borders in hyprland.lua;
    -- later rules win, so repaint them cream and square. theme_apply disables these
    -- again on the next switch.
    rule({ name = "theme-popups",
        match = { class = "^(blueman-manager|impala-popup|bluetui-popup|wiremix-popup)$" },
        border_color = "rgb(EDE8DF) rgb(EDE8DF)", rounding = 0, opacity = "1.0 1.0" })
    rule({ name = "theme-scratchpad", match = { workspace = "special:magic" },
        border_color = "rgb(FFCF4A) rgb(FFCF4A)" })
end
