Generators for the neo-brutal Qt themes (live under ~/.config/theme/tools via the stow link; no theme.json, so the picker ignores this dir).

- `genkv.py`  — recolours `qt/.config/Kvantum/CatppuccinMocha` into `NeoBrutalLight` / `NeoBrutalDark`.
- `genqt.py`  — writes the qt6ct colour files and KDE `.colors` schemes.

Re-run after changing a palette: `python3 ~/.config/theme/tools/genkv.py && python3 ~/.config/theme/tools/genqt.py`.
