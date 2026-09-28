#!/usr/bin/env python3
"""contrast.py -- WCAG contrast check for a theme's kitty.conf fragment.

  uv run --with pillow theme/.config/theme/tools/contrast.py [theme ...]

With no argument, every theme directory that has a kitty.conf is checked.
Rules (exit status 1 if any is broken):
  foreground, color1-7, color9-15   >= 4.5 against the background
  selection, cursor, tabs, marks    >= 4.5 fg against their own bg
  color0 / color8                   reported only (they are "black" and
                                    "dim"; fish uses color8 for suggestions)
When background_opacity < 1 the terminal is see-through, so the text is also
checked against the background composited over the theme's wallpaper.png --
over the lightest and the darkest spot of a 32px-wide downscale, which stands
in for Hyprland's blur. Needs Pillow for that part; skipped (and said so)
without it.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
THEMES = os.path.dirname(HERE)
MIN = 4.5


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def over(fg, bg, alpha):
    return tuple(round(f * alpha + b * (1 - alpha)) for f, b in zip(fg, bg))


def parse(path):
    out = {}
    with open(path) as f:
        for line in f:
            parts = [] if line.lstrip().startswith("#") else line.split()  # no inline comments in kitty
            if len(parts) >= 2:
                out[parts[0]] = parts[1]
    return out


def backdrops(theme_dir):
    """Lightest and darkest spot of the (downscaled = roughly blurred) wallpaper."""
    wp = os.path.join(theme_dir, "wallpaper.png")
    if not os.path.isfile(wp):
        return [], "no wallpaper.png"
    try:
        from PIL import Image
    except ImportError:
        return [], "Pillow missing, wallpaper not checked"
    im = Image.open(wp).convert("RGB")
    im = im.resize((32, max(1, round(32 * im.height / im.width))), Image.BILINEAR)
    px = list(im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata())
    px.sort(key=lum)
    return [("wallpaper-light", px[-1]), ("wallpaper-dark", px[0])], ""


def check(name):
    d = os.path.join(THEMES, name)
    k = parse(os.path.join(d, "kitty.conf"))
    bg = rgb(k["background"])
    opacity = float(k.get("background_opacity", "1"))
    grounds = [("bg", bg)]
    note = ""
    if opacity < 1:
        bds, note = backdrops(d)
        grounds += [(n, over(bg, c, opacity)) for n, c in bds]
    bad = 0
    print(f"== {name}  background {k['background']}  opacity {opacity:g}"
          + (f"  ({note})" if note else ""))
    for gname, g in grounds[1:]:
        print(f"   {gname}: composite #{''.join(f'{v:02x}' for v in g)}")

    def row(label, fg, strict, grounds_):
        nonlocal bad
        rs = [ratio(rgb(fg), g) for _, g in grounds_]
        worst = min(rs)
        ok = worst >= MIN
        tag = "ok  " if ok else ("FAIL" if strict else "info")
        if strict and not ok:
            bad += 1
        detail = "  ".join(f"{n}={r:5.2f}" for (n, _), r in zip(grounds_, rs))
        print(f"   {tag} {label:22} {fg}  {detail}")

    row("foreground", k["foreground"], True, grounds)
    for i in range(16):
        key = f"color{i}"
        if key in k:
            row(key, k[key], i not in (0, 8), grounds)
    pairs = [("selection", "selection_foreground", "selection_background"),
             ("cursor", "cursor_text_color", "cursor"),
             ("active_tab", "active_tab_foreground", "active_tab_background"),
             ("inactive_tab", "inactive_tab_foreground", "inactive_tab_background")]
    pairs += [(f"mark{i}", f"mark{i}_foreground", f"mark{i}_background") for i in (1, 2, 3)]
    for label, f, b in pairs:
        if f in k and b in k:
            row(label, k[f], True, [(b, rgb(k[b]))])
    return bad


def main(argv):
    names = argv or sorted(n for n in os.listdir(THEMES)
                           if os.path.isfile(os.path.join(THEMES, n, "kitty.conf")))
    bad = sum(check(n) for n in names)
    print(f"\n{bad} failure(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
