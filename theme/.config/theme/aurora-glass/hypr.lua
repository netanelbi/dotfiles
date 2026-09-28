-- Aurora Glass: Hyprland look. Frosted glass over a colour-field wallpaper:
-- 1px white-translucent hairline, radius 18, a big soft violet-black shadow,
-- strong blur behind every translucent surface (kitty is 0.72 opaque, the
-- Quickshell layers get blur rules below).
-- Keys must mirror catppuccin-mocha/hypr.lua (see the note there).
return function(base, rule, layer)
    hl.config({
        general = {
            gaps_in     = 6,   -- window gap 12 = the mockup's --gap
            gaps_out    = 12,
            border_size = 1,
            col = {
                active_border   = "rgba(ffffff8c)",
                inactive_border = "rgba(ffffff38)",
            },
        },
        decoration = {
            rounding         = 18,
            rounding_power   = 2,
            active_opacity   = 1,
            inactive_opacity = 0.94,
            blur = {
                enabled           = true,
                size              = 10,
                passes            = 3,
                noise             = 0.02,
                contrast          = 0.9,
                brightness        = 1,
                vibrancy          = 0.35,
                vibrancy_darkness = 0.2,
                popups            = true,   -- Kvantum menus are ~90% opaque
            },
            shadow = {
                enabled        = true,
                range          = 40,
                render_power   = 2,
                sharp          = false,
                offset         = "0 10",
                scale          = 1,
                color          = "rgba(0a00287f)",
                color_inactive = "rgba(0a002859)",
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
        border_color = "rgba(ffffff8c) rgba(ffffff38)", rounding = 18, opacity = "0.9 0.85" })
    rule({ name = "scratchpad", match = { workspace = "special:magic" },
        border_color = "rgba(ffe39ecc) rgba(ffe39e88)" })
    -- Glass panels: blur what is under each Quickshell surface, only where it
    -- paints: the bar's fill is 12% white, so the cut-off sits just below
    -- it; its soft shadow (up to ~0.35 alpha at the strip edge) still blurs in
    -- a thin band, which alpha alone cannot separate from the fill.
    layer({ name = "layers",
        match = { namespace = "^quickshell-(bar|calendar|launcher|notifications|notification-center|osd|polkit|themepicker|share-picker|board-.*)$" },
        blur = true, blur_popups = true, ignore_alpha = 0.1 })
end
