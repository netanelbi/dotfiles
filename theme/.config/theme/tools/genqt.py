#!/usr/bin/env python3
"""genqt.py -- KDE colour scheme, kdeglobals fragment and qt6ct palette per theme.

    genqt.py              every theme except catppuccin-mocha
    genqt.py paper void   just these

Writes, for each theme:
  qt/.local/share/color-schemes/<apps.kdeColorScheme>.colors
  theme/.config/theme/<name>/kdeglobals.ini     (theme-switch merges it key by key)
  theme/.config/theme/<name>/qt6ct-colors.conf  (21 QPalette roles)

Both KDE files are built by walking catppuccin-mocha's OWN files line by line
and replacing values, so their groups and keys are exactly catppuccin's:
switching back to catppuccin-mocha then rewrites every key a theme touched.
The colours come from the same Model as the Kvantum theme (genkv.py), so the
selection, buttons and tooltips agree between Kvantum and KColorScheme.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from themecolor import (C, REPO, THEMES, Model, argb, contrast, generated_themes, load, mix,  # noqa: E402
                        on, over, rgbcsv)

CAT_COLORS = os.path.join(REPO, "qt/.local/share/color-schemes/CatppuccinMocha.colors")
CAT_KDG = os.path.join(THEMES, "catppuccin-mocha/kdeglobals.ini")
QT_ROLES = ("WindowText Button Light Midlight Dark Mid Text BrightText ButtonText Base Window Shadow "
            "Highlight HighlightedText Link LinkVisited AlternateBase NoRole ToolTipBase ToolTipText "
            "PlaceholderText").split()


def legible(fg, bg, fallback, need=3.0):
    return fg if contrast(fg, bg) >= need else fallback


def kde_groups(m):
    """{group: {key: colour}} for every [Colors:*] group and [WM]."""
    btn = over(m.layer(m.tintAlpha) if m.glass else
               (m.base if (not m.dark and m.border) else (m.s0 if (m.dark and m.border) else m.s1)), m.window)
    hover_deco = m.borderActive if m.border else m.accent
    fg = {"ForegroundNormal": m.text, "ForegroundInactive": m.sub0, "ForegroundActive": m.accent2,
          "ForegroundLink": m.link, "ForegroundVisited": m.visited, "ForegroundNegative": m.err,
          "ForegroundNeutral": m.warn, "ForegroundPositive": m.ok,
          "DecorationFocus": m.focus, "DecorationHover": hover_deco}

    def group(bg, alt, inverse=False):
        g = {"BackgroundNormal": bg, "BackgroundAlternate": alt}
        if not inverse:
            g.update({k: legible(v, bg, m.text) for k, v in fg.items()})
        else:
            # light themes: tooltips and complementary areas are inverse (dark) surfaces
            g.update({"ForegroundNormal": m.base, "ForegroundInactive": mix(m.base, m.text, 0.35)})
            for k in ("ForegroundActive", "ForegroundLink", "ForegroundVisited", "ForegroundNegative",
                      "ForegroundNeutral", "ForegroundPositive", "DecorationFocus", "DecorationHover"):
                g[k] = legible(fg[k], bg, mix(fg[k], m.base, 0.65), 4.0)
        return g

    inv = not m.dark
    tip_bg = m.text if inv else m.crust
    out = {
        "Colors:View": group(m.base, mix(m.base, m.s0, 0.5)),
        "Colors:Window": group(m.window, m.base),
        "Colors:Button": group(btn, mix(btn, m.text, 0.08)),
        "Colors:Tooltip": group(tip_bg, mix(tip_bg, m.base, 0.1), inverse=inv),
        "Colors:Header": group(m.crust, m.window),
        "Colors:Complementary": group(tip_bg, mix(tip_bg, m.base, 0.1), inverse=inv),
    }
    sel = {"BackgroundNormal": m.sel, "BackgroundAlternate": m.s1}
    for k, v in fg.items():
        if k in ("ForegroundNormal", "ForegroundInactive", "ForegroundActive"):
            sel[k] = m.onSel
        else:
            sel[k] = legible(v, m.sel, m.onSel)
    out["Colors:Selection"] = sel
    out["WM"] = {"activeBackground": m.window, "activeForeground": m.text,
                 "inactiveBackground": m.crust, "inactiveForeground": m.sub0}
    return out


def rewrite(template, m, scheme, label=None):
    """Walk a catppuccin KDE file; replace every value, keep every key and line."""
    groups = kde_groups(m)
    out, cur, seen = [], None, set()
    for line in open(template).read().split("\n"):
        s = line.strip()
        if s.startswith("["):
            cur = s[1:-1]
            out.append(line)
            continue
        if "=" not in s or cur is None:
            out.append(line)
            continue
        k = s.split("=", 1)[0]
        if cur == "General" and k == "ColorScheme":
            v = scheme
        elif cur == "General" and k == "Name":
            v = label
        elif cur in groups and k in groups[cur]:
            v = rgbcsv(groups[cur][k])
        else:
            raise SystemExit(f"genqt: no value for [{cur}] {k} in {template}")
        seen.add((cur, k))
        out.append(f"{k}={v}")
    return "\n".join(out), seen


def qt6ct(m):
    tip_bg = m.crust if m.dark else m.text
    btn = over(m.layer(m.tintAlpha) if m.glass else
               (m.base if (not m.dark and m.border) else (m.s0 if (m.dark and m.border) else m.s1)), m.window)
    dark_role = C("#000000") if m.dark else m.s2
    act = {
        "WindowText": m.text, "Button": btn,
        "Light": m.s2 if m.dark else C("#ffffff"), "Midlight": m.s1 if m.dark else m.base,
        "Dark": dark_role, "Mid": m.crust if m.dark else m.s1,
        "Text": m.text, "BrightText": on(dark_role, C("#ffffff"), m.text), "ButtonText": m.text,
        "Base": m.base, "Window": m.window, "Shadow": C("#000000") if m.dark else m.text,
        "Highlight": m.sel, "HighlightedText": m.onSel,
        "Link": m.link, "LinkVisited": m.visited, "AlternateBase": mix(m.base, m.s0, 0.5),
        "NoRole": m.base, "ToolTipBase": tip_bg, "ToolTipText": on(tip_bg, m.text, m.base),
        "PlaceholderText": mix(m.base, m.sub0, 0.8),
    }
    dis = dict(act)
    for r in ("WindowText", "Text", "ButtonText", "HighlightedText"):
        dis[r] = m.ov
    dis["ToolTipText"] = mix(tip_bg, act["ToolTipText"], 0.5)
    dis["Highlight"] = m.s1
    ina = dict(act)
    ina["Highlight"], ina["HighlightedText"] = m.s1, m.text
    line = lambda d: ", ".join(argb(d[r]) for r in QT_ROLES)
    return (f"# {m.label} palette for qt6ct -- generated by theme/.config/theme/tools/genqt.py\n"
            f"# from theme.json, alongside the Kvantum theme {m.t['apps']['kvantum']}. Do not edit.\n"
            "# 21 entries in QPalette role order; see qt/.config/qt6ct/colors/catppuccin-mocha.conf.\n"
            "[ColorScheme]\n"
            f"active_colors={line(act)}\ndisabled_colors={line(dis)}\ninactive_colors={line(ina)}\n")


def build(name):
    t = load(name)
    m = Model(t)
    scheme = t["apps"]["kdeColorScheme"]
    colors, k1 = rewrite(CAT_COLORS, m, scheme, m.label)
    frag, k2 = rewrite(CAT_KDG, m, scheme)
    # the fragment must carry exactly catppuccin's key set, or switching back leaves strays
    _, kcat = rewrite(CAT_KDG, m, scheme)
    assert k2 == kcat and k2 <= k1, "key sets drifted"
    header = (f"# {m.label}: generated by theme/.config/theme/tools/genqt.py from theme.json. Do not edit.\n")
    with open(os.path.join(REPO, "qt/.local/share/color-schemes", scheme + ".colors"), "w") as f:
        f.write(colors)
    d = os.path.join(THEMES, name)
    with open(os.path.join(d, "kdeglobals.ini"), "w") as f:
        f.write(header + frag)
    with open(os.path.join(d, "qt6ct-colors.conf"), "w") as f:
        f.write(qt6ct(m))
    print(f"{scheme}: ok")


def main(argv):
    for n in argv or generated_themes():
        build(n)


if __name__ == "__main__":
    main(sys.argv[1:])
