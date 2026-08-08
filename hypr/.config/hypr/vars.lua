-- Shared programs / modifiers, required by hyprland.lua and the machine fragments.
-- Unlike the old $mainMod/$terminal hyprlang vars, these carry no ordering
-- constraint: a fragment can require() this whenever it likes.

return {
    mainMod  = "SUPER",
    terminal = "kitty",
    menu     = "rofi -show drun",
}
