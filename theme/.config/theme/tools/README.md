Generators for the Qt/GTK side of every theme except catppuccin-mocha (whose files
are hand-kept). They live under ~/.config/theme/tools via the stow link; the dir has
no theme.json, so theme-switch and the picker ignore it. Everything is read from
each theme's theme.json (palette, roles, shape, surface, bar.workspaces, apps).

- `themecolor.py` -- colour maths plus `Model`, the semantic colours all three share.
- `genkv.py`  -- Kvantum theme `qt/.config/Kvantum/<apps.kvantum>/`. Frame sets
  (buttons, fields, tabs, menus, views, sliders...) and check/radio/slider handles
  are drawn from the theme's shape; the template's other artwork is recoloured
  through a role map that fails on any unmapped colour. Rules in the docstring.
- `genqt.py`  -- KDE `.colors` scheme, the theme's `kdeglobals.ini` fragment (same
  key set as catppuccin's, asserted) and `qt6ct-colors.conf`.
- `gengtk.py` -- the theme's `gtk.css`: libadwaita colour variables.

Re-run after changing a theme.json, then restow if a theme was added:

    cd ~/.config/theme/tools && ./genkv.py && ./genqt.py && ./gengtk.py
    cd ~/.dotfiles && stow -R qt
