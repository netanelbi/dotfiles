"""Colour helpers shared by genkv.py, genqt.py and gengtk.py.

theme.json colours are CSS order: #rgb, #rrggbb or #rrggbbaa (alpha LAST).
A colour here is a tuple (r, g, b, a) with r/g/b in 0..255 and a in 0..1.
"""
import json
import os

HERE = os.path.dirname(os.path.realpath(__file__))
THEMES = os.path.dirname(HERE)                          # <repo>/theme/.config/theme
REPO = os.path.dirname(os.path.dirname(os.path.dirname(THEMES)))


def parse(s):
    h = s.strip().lstrip("#")
    if len(h) in (3, 4):
        h = "".join(c * 2 for c in h)
    if len(h) not in (6, 8):
        raise ValueError(f"bad colour {s!r}")
    a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def C(x):
    return parse(x) if isinstance(x, str) else x


def alpha(c, a):
    r, g, b, _ = C(c)
    return (r, g, b, a)


def mix(a, b, t):
    """t=0 -> a, t=1 -> b (alpha mixed too)."""
    a, b = C(a), C(b)
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3)) + (a[3] + (b[3] - a[3]) * t,)


def over(fg, bg):
    """Flatten fg (with alpha) over an opaque bg."""
    fg, bg = C(fg), C(bg)
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)


def hex6(c):
    r, g, b, _ = C(c)
    return "#%02x%02x%02x" % (round(r), round(g), round(b))


def hex8(c):
    """#rrggbbaa, or #rrggbb when opaque (Kvantum reads both)."""
    c = C(c)
    if c[3] >= 0.999:
        return hex6(c)
    return hex6(c) + "%02x" % round(c[3] * 255)


def argb(c):
    """Qt #aarrggbb (qt6ct palettes)."""
    c = C(c)
    return "#%02x" % round(c[3] * 255) + hex6(c)[1:]


def rgbcsv(c):
    """KDE colour-scheme form: r,g,b (opaque)."""
    r, g, b, _ = C(c)
    return f"{round(r)},{round(g)},{round(b)}"


def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b, _ = C(c)
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def on(bg, *candidates):
    """The candidate with the best contrast on bg."""
    return max(candidates, key=lambda c: contrast(c, bg))


def transparent(c):
    return C(c)[3] < 0.004


def load(name):
    with open(os.path.join(THEMES, name, "theme.json")) as f:
        return json.load(f)


def generated_themes():
    """Every theme except catppuccin-mocha, whose Qt files are hand-kept."""
    out = []
    for n in sorted(os.listdir(THEMES)):
        p = os.path.join(THEMES, n, "theme.json")
        if n != "catppuccin-mocha" and os.path.isfile(p):
            out.append(n)
    return out


class Model:
    """The semantic colours every Qt/GTK generator needs, read from theme.json.

    Absent roles fall back the way catppuccin-mocha uses its palette, so a
    theme.json with no "roles" block still generates something sane.
    """

    def __init__(self, t):
        P, R = t["palette"], t.get("roles", {})
        S, SU = t.get("shape", {}), t.get("surface", {})
        self.t = t
        self.name, self.label = t["name"], t.get("label", t["name"])
        self.dark = bool(t.get("dark", True))
        self.base, self.window, self.crust = C(P["base"]), C(P["mantle"]), C(P["crust"])
        self.text, self.sub0, self.sub1 = C(P["text"]), C(P["subtext0"]), C(P["subtext1"])
        self.s0, self.s1, self.s2, self.ov = C(P["surface0"]), C(P["surface1"]), C(P["surface2"]), C(P["overlay0"])
        self.P = {k: C(v) for k, v in P.items()}
        self.accent = C(R.get("accent", P["mauve"]))
        self.onAccent = C(R.get("onAccent") or hex6(on(self.accent, self.base, self.text)))
        self.accent2 = C(R.get("accent2", P["peach"]))
        self.focus = C(R.get("focus", self.accent))
        self.onFocus = on(self.focus, self.base, self.text, self.onAccent)
        sel = C(R.get("selection", P["surface1"]))
        self.selRaw = sel
        self.sel = over(sel, self.base)                 # flattened, for palettes
        self.onSel = C(R.get("onSelection", P["text"]))
        self.hover = C(R.get("hover", P["surface0"]))
        # pressed/toggled controls: the tonal container when there is one
        self.press = C(R.get("container") or self.accent)
        self.onPress = C(R.get("onContainer") or self.onAccent)
        self.ok = C(R.get("ok", P["green"]))
        self.warn = C(R.get("warn", P["yellow"]))
        self.err = C(R.get("err", P["red"]))
        self.link, self.visited = C(P["blue"]), C(P["mauve"])
        self.border = float(S.get("border", 0))
        self.borderColor = C(S.get("borderColor", "#00000000"))
        self.borderActive = C(S.get("borderActive", S.get("borderColor", "#00000000")))
        self.borderSoft = C(S.get("borderSoft", "#00000000"))
        self.radius = float(S.get("radius", 8))
        self.chip = float(S.get("chipRadius", self.radius / 2))
        self.softShadow = S.get("softShadow")
        self.opacity = float(SU.get("opacity", 1.0))
        self.blur = bool(SU.get("blur", False))
        # "glass": translucent AND tinted -- fills are white-alpha layers, not palette greys
        self.glass = self.opacity < 1 and "tint" in SU
        self.tint = C(SU.get("tint", "#ffffff"))
        self.tintAlpha = float(SU.get("tintAlpha", 0.1))
        bar = t.get("bar", {})
        self.workspaces = bar.get("workspaces", "pills")

    def layer(self, a):
        """A glass layer of strength a (white-alpha), or a tone over the window."""
        return alpha(self.tint, a) if self.glass else mix(self.window, self.text, a)
