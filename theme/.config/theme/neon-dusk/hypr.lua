-- Neon Dusk: Hyprland look. Synthwave: 1px border, pink->cyan gradient on the
-- focused window, dim pink on the rest, and a coloured glow instead of a
-- shadow -- cyan around the focused window, pink around the others (the
-- mockup's --sh-active / --sh). Light blur for the translucent surfaces.
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule, layer)
    hl.config({
        general = {
            gaps_in     = 6,   -- window gap 12 = the mockup's --gap
            gaps_out    = 12,
            border_size = 1,
            col = {
                active_border   = { colors = { "rgb(ff38ac)", "rgb(2de2e6)" }, angle = 45 },
                inactive_border = "rgba(ff38ac8c)",
            },
        },
        decoration = {
            rounding         = 6,
            rounding_power   = 2,
            active_opacity   = 1,
            inactive_opacity = 1,
            blur = {
                enabled           = true,
                size              = 4,
                passes            = 2,
                noise             = 0.0117,
                contrast          = 0.8916,
                brightness        = 1,
                vibrancy          = 0.1696,
                vibrancy_darkness = 0,
                popups            = true,   -- Kvantum menus are ~90% opaque
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
                enabled        = true,
                range          = 22,
                render_power   = 2,
                color          = "rgba(2de2e699)",
                color_inactive = "rgba(ff38ac66)",
            },
        },
    })
    rule({ name = "popups",
        match = { class = "^(blueman-manager|impala-popup|bluetui-popup|wiremix-popup)$" },
        border_color = "rgb(2de2e6) rgba(ff38ac8c)", rounding = 6, opacity = "0.95 0.9" })
    rule({ name = "scratchpad", match = { workspace = "special:magic" },
        border_color = "rgb(f6c945) rgba(f6c9458c)" })
    layer({ name = "layers",
        match = { namespace = "^quickshell-(bar|calendar|launcher|notifications|notification-center|osd|polkit|themepicker|share-picker|board-.*)$" },
        blur = true, ignore_alpha = 0.3 })
end
