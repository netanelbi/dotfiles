#!/usr/bin/env python3
"""genkv.py -- build a Kvantum theme per desktop theme, from its theme.json.

    genkv.py              every theme except catppuccin-mocha
    genkv.py paper void   just these

Writes qt/.config/Kvantum/<apps.kvantum>/<apps.kvantum>.{kvconfig,svg}.

Template: qt/.config/Kvantum/CatppuccinMocha (Tsu Jan's Arc-derived theme).
Two kinds of SVG element are treated differently:

* FRAME SETS (button, combo, lineedit, tab, menu, menuitem, tooltip, item
  views, progress, sliders, scrollbars...) are dropped from the template and
  DRAWN HERE, because their shape is the theme's character: corner radius,
  border width and colour, underline vs ring focus. Kvantum paints a corner
  element into a frame-sized square, so the visible corner radius IS the
  frame width in the .kvconfig -- both are written from the same number.
  Checkboxes, radios and slider handles are drawn here too.
* INDICATORS (arrows, spin +/-, tab close, MDI buttons, shadows, grips) keep
  the template's artwork and are recoloured. Every template colour must have
  a role below -- an unmapped hex is an error, not a pass-through, so a light
  theme can never inherit a dark-theme white.

Shape rules, all read from theme.json:
  shape.radius == 0      square everything (paper)
  shape.radius >= 24     pill controls, via Kvantum frame.expansion (tonal)
  otherwise              controls round to min(chipRadius, 6) px,
                         panels (menus, frames, tooltips) to min(radius, 10)
  shape.border > 0       1px frames in borderColor, borderActive on hover,
                         roles.focus on focused fields
  shape.border == 0      borderless tonal fills; focused fields get a 2px
                         focus ring, or a focus UNDERLINE when
                         bar.workspaces is "dots"/"underline" (void)
  bar.workspaces in (underline, dots)   tabs are underlined in accent2
  surface.opacity < 1    translucent windows/menus (glass, neon);
                         surface.tint present -> fills are white-alpha layers
  shape.softShadow null and radius 0 -> no menu/tooltip shadows (paper)
"""
import copy
import os
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from themecolor import (C, REPO, Model, alpha, contrast, generated_themes, hex6, hex8,  # noqa: E402
                        load, mix, on, over, transparent)

SVGNS, XLINK = "http://www.w3.org/2000/svg", "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVGNS)
ET.register_namespace("xlink", XLINK)
KV = os.path.join(REPO, "qt/.config/Kvantum")
SRC = os.path.join(KV, "CatppuccinMocha")

FRAMES = ("button combo lineedit common tab floating-tab tabframe tabBarFrame menu menuitem menubaritem "
          "menubar tooltip itemview header dock progress progress-pattern slider scrollbarslider").split()
STATES = "normal focused pressed toggled disabled".split()
PARTS = "top bottom left right topleft topright bottomleft bottomright".split()
RX_FRAME = re.compile(r"^(?:expand-)?(?:%s)-(?:%s)(?:-(?:%s)(?:-\w*junct\d*)?)?(?:\d.*)?$" % (
    "|".join(map(re.escape, sorted(FRAMES, key=len, reverse=True))), "|".join(STATES), "|".join(PARTS)))
RX_IND = re.compile(r"^(?:menu-)?(?:checkbox|radio)(?:-(?:checked|tristate))?-(?:%s)$|^slidercursor-(?:%s)$"
                    % ("|".join(STATES), "|".join(STATES)))


# ---- the design: theme.json -> what every widget looks like ---------------

class Side:
    def __init__(self, w=0.0, color=None):
        self.w, self.color = (w, C(color)) if color is not None and w > 0 and not transparent(color) else (0.0, None)

    def key(self):
        return (round(self.w, 3), hex8(self.color) if self.color else None)


def S(fill=None, border=None, bw=1.0, bottom=None, bottom_w=0.0, square_bottom=False):
    """One state of a frame set: fill, uniform border, optional distinct bottom (underline)."""
    sides = {k: Side(bw, border) for k in ("top", "left", "right", "bottom")}
    if bottom is not None:
        sides["bottom"] = Side(bottom_w, bottom)
    return {"fill": C(fill) if fill is not None else None, "sides": sides, "square_bottom": square_bottom}


def design(m):
    sq = m.radius == 0
    pill = m.radius >= 24
    bw = m.border
    bc = m.borderColor if bw else None
    ba = m.borderActive if bw else None
    soft = None if transparent(m.borderSoft) else m.borderSoft
    rc = 0 if sq else min(m.chip, 6)          # controls
    rp = 0 if sq else min(m.radius, 10)       # panels
    ri = 0 if sq else min(m.chip, 6)          # item highlights
    underline_style = m.workspaces in ("underline", "dots")

    if m.glass:
        ctrl, hov = m.layer(m.tintAlpha), m.layer(m.tintAlpha + 0.08)
        field = m.layer(m.tintAlpha * 0.6)
        groove = m.layer(0.14)
    else:
        ctrl = m.base if (not m.dark and bw) else (m.s0 if (m.dark and bw) else m.s1)
        hov = mix(ctrl, m.text, 0.08)
        field = m.base if (not m.dark and bw) else (m.crust if bw else m.s0)
        groove = m.s1
    menu = m.s0 if (not m.dark and not bw) else m.base
    frame_line = bc if bw else soft
    fw = 2.0 if (bw and hex8(m.focus) == hex8(m.borderColor)) else max(bw, 1.0)

    d = {"sq": sq, "pill": pill, "underline_style": underline_style,
         "fill": {"ctrl": ctrl, "hover": hov, "field": field, "groove": groove, "menu": menu}}

    # frame px per widget; the corner radius equals it unless sq
    def fpx(r, sq_default):
        return sq_default if sq else max(2, int(round(r)))
    d["frame"] = {
        "button": fpx(rc, 3), "combo": fpx(rc, 3), "lineedit": fpx(rc, 3),
        "tab": fpx(ri, 4), "tabframe": fpx(min(rp, 8), 4), "common": fpx(min(rp, 8), 3),
        "menu": fpx(rp, 1 if sq else 3), "menuitem": fpx(ri, 3), "menubaritem": fpx(ri, 2),
        "tooltip": fpx(min(rp, 6), 3), "itemview": fpx(ri, 2),
        "progress": 3, "slider": 3, "scrollbarslider": 6, "tabBarFrame": 4,
    }

    st = {}
    st["button"] = {"normal": S(ctrl, bc, bw), "focused": S(hov, ba, bw),
                    "pressed": S(m.press, m.press if bw else None, bw),
                    "toggled": S(m.press, m.press if bw else None, bw)}
    st["combo"] = {"normal": S(ctrl, bc, bw), "focused": S(hov, ba, bw),
                   "pressed": S(hov, m.focus if bw else None, bw), "toggled": S(hov, m.focus if bw else None, bw)}
    if bw:
        st["lineedit"] = {"normal": S(field, bc, bw), "focused": S(field, m.focus, fw)}
    elif underline_style:
        line = soft or m.s2
        st["lineedit"] = {"normal": S(field, bottom=line, bottom_w=1, square_bottom=True),
                          "focused": S(field, bottom=m.focus, bottom_w=2, square_bottom=True)}
    else:
        st["lineedit"] = {"normal": S(field), "focused": S(field, m.focus, 2)}
    if underline_style:
        st["tab"] = {"normal": S(None), "focused": S(m.hover),
                     "toggled": S(None, bottom=m.accent2, bottom_w=2, square_bottom=True)}
    else:
        st["tab"] = {"normal": S(None), "focused": S(m.hover),
                     "toggled": S(m.selRaw, ba, bw)}
    st["floating-tab"] = st["tab"]
    st["tabframe"] = {"normal": S(m.base, frame_line, 1)}
    # the strip behind the tab bar: a hairline under it, nothing else
    st["tabBarFrame"] = {"normal": {"fill": None, "sides": {"top": Side(), "left": Side(), "right": Side(),
                                                            "bottom": Side(1, frame_line or m.s1)},
                                    "square_bottom": True}}
    st["common"] = {"normal": S(None, frame_line, 1)}
    st["dock"] = {"normal": S(m.window, frame_line, 1), "focused": S(m.window, frame_line, 1)}
    st["menu"] = {"normal": S(menu, frame_line, 1)}
    st["menuitem"] = {s: S(m.selRaw) for s in ("focused", "pressed", "toggled")}
    st["menubaritem"] = {s: S(m.selRaw) for s in ("focused", "pressed", "toggled")}
    st["menubar"] = {"normal": S(m.window)}
    if m.dark:
        st["tooltip"] = {"normal": S(m.crust, frame_line or m.s1, 1)}
    else:
        st["tooltip"] = {"normal": S(m.text)}   # inverse surface on light themes
    st["itemview"] = {"focused": S(m.hover), "pressed": S(m.selRaw), "toggled": S(m.selRaw)}
    hline = frame_line or m.s1
    st["header"] = {s: {"fill": C(f), "sides": {"top": Side(), "left": Side(), "right": Side(1, hline),
                                                "bottom": Side(1, hline)}, "square_bottom": True}
                    for s, f in (("normal", m.window), ("focused", m.hover), ("pressed", m.hover),
                                 ("toggled", m.window))}
    if sq:
        st["progress"] = {"normal": S(m.base, m.text, 1)}
    else:
        st["progress"] = {"normal": S(groove)}
    st["progress-pattern"] = {"normal": S(m.focus), "disabled": S(m.ov)}
    st["slider"] = {"normal": S(groove), "toggled": S(m.focus)}
    st["scrollbarslider"] = {"normal": S(m.ov), "focused": S(m.sub0), "pressed": S(m.focus)}
    d["states"] = st
    # pill = frames expand until they meet (Kvantum frame.expansion)
    d["expansion"] = {"button": 64 if pill else 6, "combo": 64 if pill else 6, "lineedit": 64 if pill else 0,
                      "tab": 64 if pill else 0, "itemview": 48 if pill else 0,
                      "progress": 0 if sq else 8, "scrollbarslider": 0 if sq else 48}
    d["square"] = {k: sq for k in FRAMES}
    d["square"]["header"] = True
    d["square"]["tabBarFrame"] = True
    d["square"]["menubar"] = True
    return d


# ---- SVG drawing ----------------------------------------------------------

U = 12.0   # SVG units per corner box / strip


def paint(c):
    c = C(c)
    s = f"fill:{hex6(c)}"
    if c[3] < 0.999:
        s += f";fill-opacity:{c[3]:.3f}"
    return s


class Canvas:
    def __init__(self):
        self.items, self.x, self.y = [], 0.0, 1300.0

    def slot(self, w, h):
        if self.x + w > 440:
            self.x, self.y = 0.0, self.y + 40
        x = self.x
        self.x += w + 6
        return x, self.y

    def add(self, id_, inner, w, h):
        x, y = self.slot(w, h)
        g = [f'<g id="{id_}">', f'<rect x="{x:.3f}" y="{y:.3f}" width="{w}" height="{h}" style="fill:#000000;fill-opacity:0"/>']
        g.append(f'<g transform="translate({x:.3f},{y:.3f})">{inner}</g>')
        g.append("</g>")
        self.items.append("".join(g))


def rect(x, y, w, h, c):
    if c is None or w <= 0 or h <= 0 or transparent(c):
        return ""
    return f'<rect x="{x:.3f}" y="{y:.3f}" width="{w:.3f}" height="{h:.3f}" style="{paint(c)}"/>'


def frame_set(cv, base, state, spec, f, square):
    """9 elements for one state. f = frame px (corner radius when round).

    Border widths are px/f of a box, so for widgets that Kvantum expands into
    pills pass the EXPANDED corner size (about half a control's height) as f.
    """
    fill, sides, sqb = spec["fill"], spec["sides"], spec["square_bottom"]
    def t(side):
        return min(U, U * sides[side].w / f) if sides[side].color is not None else 0.0
    def col(side):
        return sides[side].color
    name = f"{base}-{state}"

    # interior
    cv.add(name, rect(0, 0, U, U, fill), U, U)
    # edges: drawn as the TOP edge in local space, then rotated
    def edge(side):
        tw = t(side)
        return rect(0, 0, U, tw, col(side)) + rect(0, tw, U, U - tw, fill)
    rot = {"top": "", "bottom": f"translate(0,{U}) scale(1,-1)",
           "left": f"translate(0,{U}) rotate(-90)", "right": f"translate({U},0) rotate(90)"}
    for side in ("top", "bottom", "left", "right"):
        cv.add(f"{name}-{side}", f'<g transform="{rot[side]}">{edge(side)}</g>', U, U)

    # corners: drawn as TOPLEFT (sides a=top, b=left) then flipped
    def corner(a, b, square_here):
        ta, tb = t(a), t(b)
        same = sides[a].key() == sides[b].key()
        if square_here or not same:
            out = rect(tb, ta, U - tb, U - ta, fill)
            out += rect(0, 0, U, ta, col(a)) + rect(0, ta, tb, U - ta, col(b))
            return out
        r, tt = U, ta
        out = ""
        if fill is not None and not transparent(fill):
            ri = r - tt
            if ri > 0:
                out += (f'<path d="M {U:.3f},{U:.3f} L {U - ri:.3f},{U:.3f} A {ri:.3f},{ri:.3f} 0 0 1 '
                        f'{U:.3f},{U - ri:.3f} Z" style="{paint(fill)}"/>')
        if tt > 0:
            ri = r - tt
            out += (f'<path d="M 0,{U:.3f} A {r:.3f},{r:.3f} 0 0 1 {U:.3f},0 L {U:.3f},{tt:.3f} '
                    f'A {ri:.3f},{ri:.3f} 0 0 0 {tt:.3f},{U:.3f} Z" style="{paint(col(a))}"/>')
        return out
    flips = {"topleft": ("top", "left", "", False),
             "topright": ("top", "right", f"translate({U},0) scale(-1,1)", False),
             "bottomleft": ("bottom", "left", f"translate(0,{U}) scale(1,-1)", True),
             "bottomright": ("bottom", "right", f"translate({U},{U}) scale(-1,-1)", True)}
    for part, (a, b, tr, is_bottom) in flips.items():
        sqh = square or (is_bottom and sqb)
        cv.add(f"{name}-{part}", f'<g transform="{tr}">{corner(a, b, sqh)}</g>', U, U)


def check_path(c, w=2.0):
    return (f'<path d="M 4,8.3 L 7,11.3 L 12.3,5" style="fill:none;stroke:{hex6(c)};stroke-width:{w};'
            f'stroke-linecap:round;stroke-linejoin:round"/>')


def box(r, fill=None, border=None, bw=1.5):
    o = ""
    if fill is not None and not transparent(fill):
        o += (f'<rect x="{bw / 2}" y="{bw / 2}" width="{16 - bw}" height="{16 - bw}" rx="{r}" ry="{r}" '
              f'style="{paint(fill)}"/>')
    if border is not None:
        o += (f'<rect x="{bw / 2}" y="{bw / 2}" width="{16 - bw}" height="{16 - bw}" rx="{r}" ry="{r}" '
              f'style="fill:none;stroke:{hex6(border)};stroke-width:{bw}'
              + (f";stroke-opacity:{C(border)[3]:.3f}" if C(border)[3] < 1 else "") + '"/>')
    return o


def circle(rad, fill=None, border=None, bw=1.5):
    o = ""
    if fill is not None:
        o += f'<circle cx="8" cy="8" r="{rad}" style="{paint(fill)}"/>'
    if border is not None:
        o += f'<circle cx="8" cy="8" r="{rad - bw / 2}" style="fill:none;stroke:{hex6(border)};stroke-width:{bw}"/>'
    return o


def indicators(cv, m, d):
    sq = d["sq"]
    r = 0 if sq else max(2.0, min(m.chip / 2, 4))
    edge = m.text if sq else m.sub0
    field = d["fill"]["field"]
    for pre, on_sel in (("", False), ("menu-", True)):
        # inside menus the focused item sits on the selection fill
        e_f = m.onSel if on_sel else m.focus
        fill_c = m.onSel if on_sel else m.accent
        mark_f = m.sel if on_sel else m.onAccent
        cv.add(f"{pre}checkbox-normal", box(r, None if on_sel else field, edge), 16, 16)
        cv.add(f"{pre}checkbox-focused", box(r, None if on_sel else field, e_f), 16, 16)
        cv.add(f"{pre}checkbox-checked-normal", box(r, m.accent) + check_path(m.onAccent), 16, 16)
        cv.add(f"{pre}checkbox-checked-focused", box(r, fill_c) + check_path(mark_f), 16, 16)
        bar = lambda c: f'<rect x="4" y="7" width="8" height="2" rx="1" style="{paint(c)}"/>'
        cv.add(f"{pre}checkbox-tristate-normal", box(r, m.accent) + bar(m.onAccent), 16, 16)
        cv.add(f"{pre}checkbox-tristate-focused", box(r, fill_c) + bar(mark_f), 16, 16)
        cv.add(f"{pre}radio-normal", circle(8, None if on_sel else field, edge), 16, 16)
        cv.add(f"{pre}radio-focused", circle(8, None if on_sel else field, e_f), 16, 16)
        cv.add(f"{pre}radio-checked-normal", circle(8, m.accent) + circle(3, m.onAccent), 16, 16)
        cv.add(f"{pre}radio-checked-focused", circle(8, fill_c) + circle(3, mark_f), 16, 16)
    # slider handle
    if sq:
        h = lambda f, b: box(0, f, b)
        cv.add("slidercursor-normal", h(m.base, m.text), 16, 16)
        cv.add("slidercursor-focused", h(m.s0, m.text), 16, 16)
        cv.add("slidercursor-pressed", h(m.text, m.text), 16, 16)
        cv.add("slidercursor-disabled", h(m.base, m.ov), 16, 16)
    else:
        lift = mix(m.focus, m.text if m.dark else m.base, 0.2)
        ring = m.window
        cv.add("slidercursor-normal", circle(8, ring) + circle(6.5, m.focus), 16, 16)
        cv.add("slidercursor-focused", circle(8, ring) + circle(6.5, lift), 16, 16)
        cv.add("slidercursor-pressed", circle(8, ring) + circle(6.5, lift), 16, 16)
        cv.add("slidercursor-disabled", circle(8, ring) + circle(6.5, m.ov), 16, 16)


# ---- recolouring the kept template artwork --------------------------------

def global_map(m):
    line = m.borderColor if m.border else (m.borderSoft if not transparent(m.borderSoft) else m.s2)
    alt = mix(m.base, m.s0, 0.5)
    return {
        "#1e1e2e": m.base, "#181825": m.window, "#11111b": line, "#313244": m.s0, "#45475a": m.s1,
        "#363849": m.crust, "#232334": m.s0, "#1b1b2a": m.window, "#141420": m.s1, "#0b0b12": m.onAccent,
        "#262637": m.s0, "#1a1a28": m.window, "#121220": line, "#171724": m.base, "#242436": alt,
        "#22242e": line, "#2b2e39": line, "#323542": m.s1, "#31353f": m.s1, "#474d5b": m.s2,
        "#444448": m.s1, "#222224": m.s0, "#141414": m.base, "#1e1e1e": m.base,
        "#cba6f7": m.accent, "#b4befe": m.focus, "#9d7cd8": m.accent2, "#f5c2e7": m.accent2,
        "#574a82": m.sel, "#9399b2": m.sub0, "#7f849c": m.ov, "#ffffff": m.text, "#000000": C("#000000"),
        "#a0a0a0": m.sub0, "#c3c3c3": m.text, "#787878": m.ov, "#d7d7d7": m.sub1, "#b4b4b4": m.sub0,
        "#acb1bc": m.s2, "#5a616e": m.accent, "#5a5a5a": m.sub0, "#505050": m.ov, "#666666": m.sub0,
        "#7b7b7b": m.ov, "#969696": m.ov, "#d2d2d2": m.sub1, "#0582ff": m.accent, "#3399ff": m.focus,
        "#f04a50": m.err,
    }


def owner_map(m):
    """Owner element id -> colour for ALL its paint, overriding the global map."""
    return {
        # pressed/toggled buttons are filled with m.press
        "arrow-up-pressed": m.onPress, "kv-arrow-onpress": m.onPress,
        # combos are not press-filled; their toggled arrow is plain text
        "kv-carrow-text": m.text,
        # inline spin indicators sit in the field, not on a press fill
        "spin-plus-pressed": m.focus, "spin-minus-pressed": m.focus,
        "tab-close-pressed": m.accent2 if m.border == 0 and not m.dark else m.accent,
    }


RX_COLORPROP = re.compile(r"((?:^|;)\s*(?:fill|stroke|stop-color)\s*:\s*)(#[0-9a-fA-F]{3,8})")


def norm(h):
    h = h.lower()
    return "#" + "".join(c * 2 for c in h[1:]) if len(h) == 4 else h


def recolour(root, m, removed_ids):
    gm, om = global_map(m), owner_map(m)
    missing = set()

    def conv(h, owner):
        h = norm(h)
        if owner in om:
            return hex6(om[owner])
        if h not in gm:
            missing.add(h)
            return h
        return hex6(gm[h])

    def walk(e, owner):
        i = e.get("id")
        if i in om:
            owner = i
        st = e.get("style")
        if st:
            e.set("style", RX_COLORPROP.sub(lambda mo: mo.group(1) + conv(mo.group(2), owner), st))
        for a in ("fill", "stroke", "stop-color"):
            v = e.get(a)
            if v and v.startswith("#"):
                e.set(a, conv(v, owner))
        for ch in e:
            walk(ch, owner)
    walk(root, None)
    if missing:
        raise SystemExit(f"genkv: template colours with no role: {sorted(missing)}")


def build_svg(m, d):
    tree = ET.parse(os.path.join(SRC, "CatppuccinMocha.svg"))
    root = tree.getroot()
    parent = {c: p for p in root.iter() for c in p}
    byid = {e.get("id"): e for e in root.iter() if e.get("id")}

    # clones for arrows whose template owner is shared between contexts
    def clone(src, new, retarget):
        e = copy.deepcopy(byid[src])
        e.set("id", new)
        for k, sub in enumerate(e.iter()):
            if sub is not e and sub.get("id"):
                sub.set("id", f"{new}-{k}")
        p = parent[byid[src]]
        p.insert(list(p).index(byid[src]) + 1, e)
        for u in retarget:
            byid[u].set(f"{{{XLINK}}}href", "#" + new)
    clone("flat-arrow-down-normal", "kv-arrow-onpress",
          [f"arrow-{s}-toggled" for s in ("up", "down", "left", "right")])
    clone("arrow-up-pressed", "kv-carrow-text", ["carrow-toggled"])

    # drop every frame set and indicator we draw ourselves
    parent = {c: p for p in root.iter() for c in p}
    doomed = [e for e in root.iter() if e.get("id") and (RX_FRAME.match(e.get("id")) or RX_IND.match(e.get("id"))
                                                         or e.get("id").startswith("unused-"))]
    gone = set()
    for e in doomed:
        if e in parent and parent[e] is not None and any(e is c for c in parent[e]):
            for sub in e.iter():
                if sub.get("id"):
                    gone.add(sub.get("id"))
            parent[e].remove(e)
    # nothing we kept may point at something we dropped
    ids = {e.get("id") for e in root.iter() if e.get("id")}
    for e in root.iter():
        h = e.get(f"{{{XLINK}}}href")
        if h and h.startswith("#") and h[1:] not in ids:
            raise SystemExit(f"genkv: kept element {e.get('id')} references dropped {h}")

    recolour(root, m, gone)

    cv = Canvas()
    for base, states in d["states"].items():
        f = d["frame"].get(base, 3)
        if d["expansion"].get(base, 0) >= 32:
            f = max(f, 16)
        for state, spec in states.items():
            frame_set(cv, base, state, spec, f, d["square"].get(base, False))
    indicators(cv, m, d)
    layer = ET.fromstring(f'<g xmlns="{SVGNS}" id="kv-generated">' + "".join(cv.items) + "</g>")
    root.append(layer)
    root.set("height", str(int(cv.y + 60)))
    return ET.tostring(root, encoding="unicode")


# ---- kvconfig -------------------------------------------------------------

class Ini:
    def __init__(self, text):
        self.lines = text.rstrip("\n").split("\n")

    def sections(self):
        out, cur = {}, None
        for i, l in enumerate(self.lines):
            if l.startswith("["):
                cur = l.strip()[1:-1]
                out.setdefault(cur, [])
            elif "=" in l and cur:
                out[cur].append((i, l.split("=", 1)[0], l.split("=", 1)[1]))
        return out

    def set(self, section, key, value):
        cur, last = None, None
        for i, l in enumerate(self.lines):
            if l.startswith("["):
                if cur == section:
                    break
                cur = l.strip()[1:-1]
            if cur == section:
                if l.strip():
                    last = i
                if l.split("=", 1)[0] == key and "=" in l:
                    self.lines[i] = f"{key}={value}"
                    return
        if last is None:
            self.lines += ["", f"[{section}]", f"{key}={value}"]
        else:
            self.lines.insert(last + 1, f"{key}={value}")

    def text(self):
        return "\n".join(self.lines) + "\n"


def text_colour(m, d, section, key, old):
    """Every text.*.color in the template, by meaning."""
    old = old.lower()
    under = d["underline_style"]
    special = {
        ("MenuItem", "text.focus.color"): m.onSel,
        ("MenuBarItem", "text.focus.color"): m.onSel,
        ("MenuBarItem", "text.normal.color"): m.text,
        ("ItemView", "text.press.color"): m.onSel,
        ("ItemView", "text.toggle.color"): m.onSel,
        ("ItemView", "text.press.inactive.color"): m.onSel,
        ("ItemView", "text.toggle.inactive.color"): m.onSel,
        ("Tab", "text.normal.color"): m.sub0,
        ("Tab", "text.focus.color"): m.text,
        ("Tab", "text.toggle.color"): m.text if under else m.onSel,
        ("HeaderSection", "text.focus.color"): m.text,
        ("HeaderSection", "text.toggle.color"): m.text,
        ("ComboBox", "text.press.color"): m.text,
        ("ToolboxTab", "text.press.color"): m.sub0,
        ("Progressbar", "text.press.color"): m.text,
        ("Progressbar", "text.toggle.color"): m.text,
        ("TitleBar", "text.normal.color"): m.sub0,
    }
    if (section, key) in special:
        return special[(section, key)]
    if key.startswith("text.press") or key.startswith("text.toggle"):
        return m.onPress
    if old in ("#a6adc8", "#6c7086", "#787878"):
        return m.sub0
    if old in ("#cdd6f4", "white", "#bac2de", "#000000b4"):
        return m.text
    if old == "#cba6f7":
        return m.accent
    raise SystemExit(f"genkv: no role for [{section}] {key}={old}")


def build_kvconfig(m, d):
    ini = Ini(open(os.path.join(SRC, "CatppuccinMocha.kvconfig")).read())
    for sec, items in ini.sections().items():
        for _, k, v in items:
            if k.startswith("text.") and k.endswith(".color"):
                ini.set(sec, k, hex8(text_colour(m, d, sec, k, v)))

    g = "%General"
    ini.set(g, "comment", f"{m.label}: generated from theme/.config/theme/{m.name}/theme.json by "
                          "theme/.config/theme/tools/genkv.py (template: CatppuccinMocha). Do not edit.")
    ini.set(g, "author", "genkv.py, after Tsu Jan's Arc-derived CatppuccinMocha")
    ini.set(g, "attach_active_tab", "false")
    ini.set(g, "inline_spin_indicators", "true")
    trans = m.opacity < 1
    ini.set(g, "translucent_windows", "true" if trans else "false")
    # Kvantum's own blurring needs KWin's blur protocol; Hyprland ignores it and
    # blurs whatever is translucent itself (decoration:blur), so leave it off.
    ini.set(g, "blurring", "false")
    ini.set(g, "popup_blurring", "false")
    if trans:
        # a window at the panels' own opacity is unreadable over the wallpaper; cap it
        ini.set(g, "reduce_window_opacity", str(min(30, round((1 - m.opacity) * 100))))
        ini.set(g, "reduce_menu_opacity", str(min(10, round((1 - m.opacity) * 100))))
    no_shadow = d["sq"] and not m.softShadow
    ini.set(g, "menu_shadow_depth", "0" if no_shadow else "5")
    ini.set(g, "tooltip_shadow_depth", "0" if no_shadow else "6")
    ini.set(g, "menu_blur_radius", str(min(10, d["frame"]["menu"]) if not d["sq"] else 0))
    ini.set(g, "tooltip_blur_radius", str(min(10, d["frame"]["tooltip"]) if not d["sq"] else 0))

    gc = "GeneralColors"
    btn = over(d["fill"]["ctrl"], m.window)
    tip_bg = m.crust if m.dark else m.text
    colors = {
        "window.color": m.window, "base.color": m.base, "alt.base.color": mix(m.base, m.s0, 0.5),
        "button.color": btn,
        "light.color": m.s2 if m.dark else C("#ffffff"),
        "mid.light.color": m.s1 if m.dark else m.base,
        "dark.color": C("#000000") if m.dark else m.s2,
        "mid.color": m.crust if m.dark else m.s1,
        "highlight.color": m.sel, "inactive.highlight.color": m.s1,
        "text.color": m.text, "window.text.color": m.text, "button.text.color": m.text,
        "disabled.text.color": m.ov, "tooltip.text.color": on(tip_bg, m.text, m.base),
        "highlight.text.color": m.onSel, "inactive.highlight.text.color": m.text,
        "link.color": m.link, "link.visited.color": m.visited,
        "progress.indicator.text.color": m.onFocus,
    }
    for k, v in colors.items():
        ini.set(gc, k, hex8(v))

    # frames: the corner radius is the frame width, so write both from design()
    F = d["frame"]
    frames = {"PanelButtonCommand": ("button", F["button"]), "ComboBox": ("combo", F["combo"]),
              "LineEdit": ("lineedit", F["lineedit"]), "Tab": ("tab", F["tab"]),
              "TabFrame": ("tabframe", F["tabframe"]), "GenericFrame": ("common", F["common"]),
              "Menu": ("menu", F["menu"]), "MenuItem": ("menuitem", F["menuitem"]),
              "MenuBarItem": ("menubaritem", F["menubaritem"]), "ToolTip": ("tooltip", F["tooltip"]),
              "ItemView": ("itemview", F["itemview"]), "Progressbar": ("progress", F["progress"]),
              "ProgressbarContents": ("progress-pattern", F["progress"]),
              "Slider": ("slider", F["slider"]), "ScrollbarSlider": ("scrollbarslider", F["scrollbarslider"])}
    for sec, (el, f) in frames.items():
        for side in ("top", "bottom", "left", "right"):
            ini.set(sec, f"frame.{side}", str(f))
    for sec, key in (("PanelButtonCommand", "button"), ("ComboBox", "combo"), ("LineEdit", "lineedit"),
                     ("Tab", "tab"), ("ItemView", "itemview"), ("Progressbar", "progress"),
                     ("ScrollbarSlider", "scrollbarslider")):
        ini.set(sec, "frame.expansion", str(d["expansion"][key]))
    # the spin box's line edit and buttons share the field look
    ini.set("IndicatorSpinBox", "frame.left", str(F["lineedit"]))
    # a frameless widget still needs its MenuBar/Toolbar frames at 0 for flat bars
    return ini.text()


def build(name):
    t = load(name)
    m = Model(t)
    kvname = t["apps"]["kvantum"]
    d = design(m)
    out = os.path.join(KV, kvname)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, kvname + ".svg"), "w") as f:
        f.write(build_svg(m, d))
    with open(os.path.join(out, kvname + ".kvconfig"), "w") as f:
        f.write(build_kvconfig(m, d))
    # audit: text on its fill must be legible
    checks = [("text/window", m.text, m.window), ("text/base", m.text, m.base),
              ("onSel/sel", m.onSel, m.sel), ("onPress/press", m.onPress, over(m.press, m.window)),
              ("onAccent/accent", m.onAccent, m.accent), ("onFocus/focus", m.onFocus, m.focus),
              ("disabled/window", m.ov, m.window)]
    low = [f"{n} {contrast(a, over(b, m.window)):.1f}" for n, a, b in checks
           if contrast(a, over(b, m.window)) < (2.5 if n.startswith("disabled") else 4.5)]
    print(f"{kvname}: ok" + (f"  (low contrast: {', '.join(low)})" if low else ""))


def main(argv):
    names = argv or generated_themes()
    for n in names:
        build(n)


if __name__ == "__main__":
    main(sys.argv[1:])
