-- Tonal: Hyprland look. Material You: no borders at all, big radius, a soft
-- neutral shadow on every window; the focused one lifts with a green-tinted
-- shadow (the mockup's --sh-active, rgba(62,106,55,.22)).
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule, layer)
    hl.config({
        general = {
            gaps_in     = 6,   -- window gap 12 = the mockup's --gap
            gaps_out    = 12,
            border_size = 0,
            col = {
                active_border   = "rgba(00000000)",
                inactive_border = "rgba(00000000)",
            },
        },
        decoration = {
            rounding         = 24,
            rounding_power   = 2,
            active_opacity   = 1,
            inactive_opacity = 1,
            blur = {
                enabled           = false,
                size              = 6,
                passes            = 2,
                noise             = 0.0117,
                contrast          = 0.8916,
                brightness        = 1,
                vibrancy          = 0.1696,
                vibrancy_darkness = 0,
                popups            = false,
            },
            shadow = {
                enabled        = true,
                range          = 18,
                render_power   = 3,
                sharp          = false,
                offset         = "0 4",
                scale          = 1,
                color          = "rgba(3e6a3766)",
                color_inactive = "rgba(0000002e)",
            },
            glow = {
                enabled        = false,
                range          = 10,
                render_power   = 3,
                color          = "rgba(33ccffee)",
                color_inactive = "rgba(33ccffee)",
            },
        },
    })
    rule({ name = "popups",
        match = { class = "^(blueman-manager|impala-popup|bluetui-popup|wiremix-popup)$" },
        rounding = 20, opacity = "1.0 1.0" })
    -- no borders anywhere else, so the scratchpad gets one: tonal's accent
    rule({ name = "scratchpad", match = { workspace = "special:magic" },
        border_size = 2, border_color = "rgb(3e6a37) rgb(3e6a37)" })
end
