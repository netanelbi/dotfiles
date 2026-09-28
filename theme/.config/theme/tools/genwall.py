#!/usr/bin/env python3
"""Render the image wallpapers for the themes-v2 themes.

    uv run --with pillow --with numpy theme/.config/theme/tools/genwall.py [theme ...]

Writes <theme>/wallpaper.png next to each theme.json. Deterministic (fixed
seeds), so re-running reproduces the committed files. The designs follow the
--wall / --wall-fx CSS of the approved prototype (neubrutal/v3/themes.html).
void has no image: its desk.mode is flat.

Rendered at 2560x1600 (16:10): above every panel this setup drives (eDP-1
1920x1200, the Dell 1920x1080). Quickshell does the aspect-correct cover crop,
so keep anything important near the centre.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

W, H = 2560, 1600
# Image pixels per logical pixel on eDP-1 (1280x800 logical at scale 1.5).
PX = W / 1280
THEMES = Path(__file__).resolve().parent.parent


def rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def grid():
    y, x = np.mgrid[0:H, 0:W].astype(np.float64)
    return x + 0.5, y + 0.5


def smooth(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def over(img, colour, alpha):
    """Composite a flat colour at per-pixel alpha onto img (H,W,3)."""
    a = alpha[..., None]
    return img * (1 - a) + rgb(colour) * a if isinstance(colour, str) else img * (1 - a) + colour * a


def finish(img, name, rng, dither=1.0):
    """Triangular dither to kill gradient banding, then quantise and save."""
    if dither:
        img = img + (rng.random(img.shape[:2]) - rng.random(img.shape[:2]))[..., None] * dither
    out = Image.fromarray(np.clip(np.rint(img), 0, 255).astype(np.uint8), "RGB")
    path = THEMES / name / "wallpaper.png"
    out.save(path, optimize=True, compress_level=9)
    print(f"{path}  {path.stat().st_size / 1e6:.2f} MB")


def radial(x, y, cx, cy, rx, ry, stop=0.6):
    """CSS radial-gradient(rx ry at cx cy, c 0, transparent stop): alpha."""
    d = np.hypot((x - cx * W) / (rx * W), (y - cy * H) / (ry * H))
    return 1 - smooth(d / stop)


def aurora_glass(rng):
    x, y = grid()
    img = np.broadcast_to(rgb("#1b1530"), (H, W, 3)).copy()
    # CSS paints the first gradient on top, so composite in reverse order.
    # Gaussian falloff rather than CSS's linear stop: the fields bleed into
    # each other the way the blurred prototype reads, with no hard rims.
    def field(cx, cy, rx, ry, sigma=0.40):
        d = np.hypot((x - cx * W) / (rx * W), (y - cy * H) / (ry * H))
        return np.exp(-(d / sigma) ** 2)
    img = over(img, "#23d5c8", 0.92 * field(0.60, 0.95, 0.60, 0.70))
    img = over(img, "#ff6fb1", 0.90 * field(0.85, 0.30, 0.50, 0.60))
    img = over(img, "#7b5cff", 0.92 * field(0.15, 0.20, 0.60, 0.70))
    # A little depth: darken the lower-left corner the fields leave empty.
    img *= (1 - 0.25 * (1 - smooth(np.hypot(x / W, (y - H) / H) / 0.6)))[..., None]
    finish(img, "aurora-glass", rng, dither=1.5)


def paper(rng):
    x, y = grid()
    img = np.broadcast_to(rgb("#f2efe8"), (H, W, 3)).copy()
    # Grain: soft low-frequency mottling plus fine fibre noise, both faint.
    low = Image.fromarray((rng.random((H // 40, W // 40)) * 255).astype(np.uint8))
    low = np.asarray(low.resize((W, H), Image.BICUBIC), dtype=np.float64) / 255 - 0.5
    img += (low * 3.0)[..., None]
    # Rules every 32 logical px, 1 logical px thick, at rgba(0,0,0,.035).
    step, thick = 32 * PX, 1 * PX
    on = ((y % step) >= step - thick).astype(np.float64)
    img = over(img, "#000000", 0.035 * on)
    finish(img, "paper", rng, dither=2.0)


def tonal(rng):
    x, y = grid()
    a = np.radians(160)
    length = abs(W * np.sin(a)) + abs(H * np.cos(a))
    t = ((x - W / 2) * np.sin(a) - (y - H / 2) * np.cos(a)) / length + 0.5
    t = np.clip(t, 0, 1)[..., None]
    img = rgb("#dfe7da") * (1 - t) + rgb("#c9d8c4") * t
    # Two very soft tonal blobs so the flat gradient has some calm depth.
    img = over(img, "#b9ccb3", 0.35 * radial(x, y, 0.82, 0.88, 0.55, 0.60, 1.0))
    img = over(img, "#eef2ea", 0.45 * radial(x, y, 0.12, 0.10, 0.50, 0.55, 1.0))
    finish(img, "tonal", rng, dither=1.5)


def neon_dusk(rng):
    x, y = grid()
    hz = 0.72 * H  # horizon
    cx = W / 2

    # Sky: #0d0221 -> #261447 (55%) -> #541a5a (72%).
    stops = [(0.0, "#0d0221"), (0.55, "#261447"), (0.72, "#541a5a")]
    t = y / H
    sky = np.zeros((H, W, 3))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        m = ((t >= t0) & (t < t1))[..., None]
        k = ((t - t0) / (t1 - t0))[..., None]
        sky = np.where(m, rgb(c0) * (1 - k) + rgb(c1) * k, sky)
    img = sky

    # Stars, upper sky only, fading out toward the horizon glow.
    n = 420
    sx, sy = rng.random(n) * W, rng.random(n) ** 1.6 * hz * 0.75
    sb = rng.random(n) ** 3
    stars = np.zeros((H, W))
    for px, py, b in zip(sx.astype(int), sy.astype(int), sb):
        stars[py, px] = 0.35 + 0.65 * b
        if b > 0.7:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                stars[min(py + dy, H - 1), min(px + dx, W - 1)] = 0.3 * b
    stars *= np.clip(1 - y / (hz * 0.8), 0, 1) ** 0.7
    img = over(img, "#ffe9f6", stars)

    # Horizon haze: pink bloom along the horizon line.
    haze = np.exp(-((y - hz) / (0.06 * H)) ** 2) * np.exp(-((x - cx) / (0.55 * W)) ** 2)
    img = over(img, "#ff38ac", 0.35 * haze)

    # Sun: centred above the horizon, sitting on it, lower half cut by gaps.
    R = 0.21 * H
    sc = hz - 0.62 * R
    d = np.hypot(x - cx, y - sc)
    glow = np.exp(-np.clip(d - R, 0, None) / (0.09 * H)) * (d > R)
    img = over(img, "#ff38ac", 0.45 * glow * (y < hz))
    k = np.clip((y - (sc - R)) / (2 * R), 0, 1)[..., None]
    sun = rgb("#f6c945") * (1 - np.clip(k / 0.8, 0, 1)) + rgb("#ff38ac") * np.clip(k / 0.8, 0, 1)
    disc = np.clip(R - d + 0.5, 0, 1)
    # Gaps: bands start at the sun's middle and grow toward the horizon.
    u = (y - sc) / R  # 0 at centre, ~0.62 at horizon
    bands = np.ones_like(u)
    edges = [0.05, 0.17, 0.28, 0.38, 0.47, 0.55, 0.62]
    for i, e in enumerate(edges):
        gap = 0.010 + 0.0065 * i
        lo, hi = e * R + sc, (e + gap) * R + sc
        bands *= 1 - np.clip(np.minimum(y - lo + 0.5, hi - y + 0.5), 0, 1)
    disc *= np.where(u > 0, bands, 1) * (y < hz)
    img = img * (1 - disc[..., None]) + sun * disc[..., None]

    # Floor below the horizon: dark violet, perspective grid to a vanishing point.
    below = y >= hz
    fk = np.clip((y - hz) / (H - hz), 0, 1)[..., None]
    floor = rgb("#1a0633") * (1 - fk) + rgb("#0d0221") * fk
    img = np.where(below[..., None], floor, img)
    # The sky's glow spills onto the floor just under the horizon.
    spill = np.exp(-np.clip(y - hz, 0, None) / (0.05 * H)) * np.exp(-((x - cx) / (0.35 * W)) ** 2)
    img = over(img, "#ff38ac", 0.30 * spill * below)

    dy = np.maximum(y - hz, 0.5)
    f = 1.0 * H  # focal length in px
    cam = 0.09 * H  # camera height (world units == px at depth f)
    z = cam * f / dy  # depth of the floor point
    wx = (x - cx) * z / f  # world x
    cell = 0.055 * H
    # Distance to nearest line, converted back to screen pixels.
    zz = z / cell
    dz_px = np.abs(zz - np.rint(zz)) * cell / (z * z / (cam * f))
    xx = wx / cell
    dx_px = np.abs(xx - np.rint(xx)) * cell / (z / f)
    lw = 1.1 * PX / 2
    line = np.maximum(np.clip(lw + 0.5 - dz_px, 0, 1), np.clip(lw + 0.5 - dx_px, 0, 1))
    bloom = np.maximum(np.exp(-(dz_px / (3.5 * PX)) ** 2), np.exp(-(dx_px / (3.5 * PX)) ** 2))
    # Fog: lines dissolve into the horizon haze instead of aliasing into mush.
    fog = smooth((y - hz) / (0.16 * H))
    vis = below * fog
    img = over(img, "#ff38ac", np.clip(0.28 * bloom * vis, 0, 1))
    img = over(img, "#ff5fc0", np.clip(0.85 * line * vis, 0, 1))
    # The horizon itself: a thin hot line.
    hl = np.exp(-((y - hz) / (1.2 * PX)) ** 2) * np.exp(-((x - cx) / (0.7 * W)) ** 2)
    img = over(img, "#ff8fd0", 0.9 * hl)
    finish(img, "neon-dusk", rng, dither=1.5)


RENDER = {"aurora-glass": aurora_glass, "paper": paper, "tonal": tonal, "neon-dusk": neon_dusk}

if __name__ == "__main__":
    for name in sys.argv[1:] or RENDER:
        RENDER[name](np.random.default_rng(7))
