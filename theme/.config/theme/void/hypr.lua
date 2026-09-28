-- Void: Hyprland look. No chrome: no shadow, no blur, no visible frame on
-- unfocused windows. Focus is a coral underline -- the border is a vertical
-- gradient that is solid coral only along the bottom edge and fades out
-- within the lowest few percent of the side borders.
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule, layer)
    hl.config({
        general = {
            gaps_in     = 5,   -- window gap 10 = the mockup's --gap
            gaps_out    = 10,
            border_size = 2,
            col = {
                active_border   = { colors = {
                    "rgba(ff7a5900)", "rgba(ff7a5900)", "rgba(ff7a5900)", "rgba(ff7a5900)",
                    "rgba(ff7a5900)", "rgba(ff7a5900)", "rgba(ff7a5900)", "rgba(ff7a5900)",
                    "rgba(ff7a5900)", "rgba(ff7a59ff)" }, angle = 90 },
                inactive_border = "rgba(00000000)",
            },
        },
        decoration = {
            rounding         = 10,
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
        border_color = "rgb(2a2a30) rgb(222227)", rounding = 10, opacity = "1.0 1.0" })
    rule({ name = "scratchpad", match = { workspace = "special:magic" },
        border_color = "rgb(ff7a59) rgba(ff7a5966)" })
end
