-- Paper: Hyprland look. A printed page: 1px ink hairline, square corners, no
-- shadow, no blur, generous margins. The focused window's rule is full ink,
-- the rest are pencil grey (the mockup draws every frame in ink, but with no
-- title bars that would leave focus invisible).
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule, layer)
    hl.config({
        general = {
            gaps_in     = 9,   -- window gap 18 = the mockup's --gap
            gaps_out    = 24,
            border_size = 1,
            col = {
                active_border   = "rgb(1d1b18)",
                inactive_border = "rgb(a8a296)",
            },
        },
        decoration = {
            rounding         = 0,
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
                enabled        = false,
                range          = 20,
                render_power   = 3,
                sharp          = false,
                offset         = "0 0",
                scale          = 1,
                color          = "rgba(00000080)",
                color_inactive = "rgba(00000080)",
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
        border_color = "rgb(1d1b18) rgb(1d1b18)", rounding = 0, opacity = "1.0 1.0" })
    -- the scratchpad is marked in the one colour paper allows: ink red
    rule({ name = "scratchpad", match = { workspace = "special:magic" },
        border_color = "rgb(b3261e) rgb(b3261e)" })
end
