#version 440
// All the live wallpaper's weather in one pass on the GPU: rain (drizzle to
// downpour), snow, fog, and the lightning that lights the rain up in a storm.
//
// This replaced a QML Canvas for the rain/snow and two sliding gradient bands
// for the fog. Each effect has its own amount uniform; at 0 it costs one
// branch, so a clear sky with only fog pays for fog and nothing else.
//
// Qt6 does not read .frag at runtime; this is compiled to weather-vN.frag.qsb
//     /usr/lib/qt6/bin/qsb --glsl 100es,120,150 --hlsl 50 --msl 12
//         -o weather-vN.frag.qsb weather.frag
// and the .qsb is what ships. Rebuild it after every edit here, BUMP N, delete
// the old one and update the path in Wallpaper.qml: Qt caches shaders by URL
// for the life of the process, so a quickshell reload keeps running the old
// .qsb under the same name -- the text changed, the picture never did.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float time;         // seconds, from the wallpaper's throttled clock
    vec2  resolution;   // logical pixels, so drops keep their size per monitor
    float rain;         // 0..1: 0.15 is a few drops, 1 is a downpour
    float drizzle;      // 0/1: fine, short, slow drops instead of streaks
    float snow;         // 0..1
    float fog;          // 0..1
    float slant;        // wind: horizontal shift per pixel of fall
    float flash;        // 0..1, lightning; lights the rain and the fog
    vec4  rainColor;
    vec4  snowColor;
    vec4  fogColor;
};

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise + fbm, for the fog. Four octaves is plenty for something this
// soft and keeps the cost flat.
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 17.0; a *= 0.5; }
    return v;
}

// One layer of rain. Columns of fixed width scroll down at their own speed;
// each cell in a column holds at most one streak, present with probability
// `prob`. Layers at different scales give depth.
float rainLayer(vec2 p, float colW, float cellH, float speed, float seed, float prob, float lenK) {
    // Shear so streaks fall along the wind instead of straight down.
    p.x += p.y * slant;
    float col  = floor(p.x / colW);
    float cs   = hash(vec2(col, seed));
    float y    = p.y - time * speed * mix(0.75, 1.25, cs) + cs * cellH * 7.0;
    float row  = floor(y / cellH);
    float rs   = hash(vec2(col, row + seed * 13.0));
    if (rs > prob) return 0.0;

    float len  = mix(0.35, 0.8, hash(vec2(row, col + seed))) * cellH * 0.35 * lenK;
    float x0   = mix(0.2, 0.8, hash(vec2(col + seed, row))) * colW;
    float ly   = fract(y / cellH) * cellH;            // 0 at the top of the cell
    float lx   = p.x - col * colW;

    float line  = 1.0 - smoothstep(0.35, 0.9, abs(lx - x0));
    // Bright head at the bottom, fading tail above it.
    float along = smoothstep(0.0, len, ly) * step(ly, len);
    float op    = mix(0.15, 0.5, hash(vec2(rs, cs)));
    return line * along * op;
}

float snowLayer(vec2 p, float cell, float speed, float seed, float prob) {
    float col  = floor(p.x / cell);
    float cs   = hash(vec2(col, seed));
    float y    = p.y - time * speed * mix(0.7, 1.3, cs) + cs * cell * 9.0;
    float row  = floor(y / cell);
    float rs   = hash(vec2(col, row + seed * 7.0));
    if (rs > prob) return 0.0;

    float r    = mix(1.6, 3.6, hash(vec2(row, col + seed)));
    vec2  c    = vec2(mix(0.25, 0.75, hash(vec2(col + seed, row))) * cell, 0.5 * cell);
    // Flakes sway on a sine rather than falling straight.
    c.x += sin(time * 1.1 + rs * 6.28) * cell * 0.18;
    vec2  l    = vec2(p.x - col * cell, fract(y / cell) * cell);
    float d    = length(l - c);
    float op   = mix(0.3, 0.75, hash(vec2(rs, cs)));
    return (1.0 - smoothstep(r - 0.8, r + 0.4, d)) * op;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p  = uv * resolution;

    // Accumulated premultiplied colour, back to front: fog, then the
    // particles in front of it.
    vec4 acc = vec4(0.0);

    // ---- fog / haze. Heavy rain brings its own haze, so a downpour reads as
    // sheets of water and not just more lines.
    float haze = max(fog, smoothstep(0.55, 1.0, rain) * 0.35);
    if (haze > 0.0) {
        vec2 q = p / resolution.y * 2.2;
        float n = fbm(q + vec2(time * 0.035, time * 0.01))
                * 0.6 + fbm(q * 0.5 - vec2(time * 0.02, 0.0)) * 0.4;
        // Pools low on the screen, thins towards the top.
        float lowBias = mix(0.45, 1.0, smoothstep(0.0, 1.0, uv.y));
        float fa = smoothstep(0.15, 0.75, n) * lowBias * haze * 0.85;
        fa = clamp(fa * (1.0 + flash * 1.2), 0.0, 1.0);
        acc = vec4(fogColor.rgb * fa, fa);
    }

    // ---- rain
    float a = 0.0;
    if (rain > 0.0) {
        // Drizzle: short, slow, fine. Rain: streaks that lengthen and speed
        // up as it gets heavier.
        float lenK = drizzle > 0.5 ? 0.3 : mix(0.45, 1.25, rain);
        float spdK = drizzle > 0.5 ? 0.45 : mix(0.75, 1.2, rain);
        // Drop count grows faster than linearly, so light rain is a scatter
        // and only a downpour fills the screen: 0.17 -> ~6% of cells, 1 -> all.
        float prob = pow(rain, 1.6);
        a  = rainLayer(p,         9.0, 220.0, 520.0 * spdK, 1.0, prob,       lenK);
        a += rainLayer(p + 31.0, 13.0, 300.0, 760.0 * spdK, 2.0, prob * 0.8, lenK);
        // The near, big layer only joins in moderate rain and up.
        float nearP = smoothstep(0.35, 1.0, rain) * 0.8;
        if (nearP > 0.0)
            a += rainLayer(p + 57.0, 17.0, 380.0, 980.0 * spdK, 3.0, nearP, lenK) * 0.9;
        a *= mix(0.7, 1.15, rain) * (1.0 + flash * 1.8);
        a = clamp(a, 0.0, 1.0);
        vec3 c = mix(rainColor.rgb, vec3(1.0), flash * 0.6);
        acc = vec4(c * a, a) + acc * (1.0 - a);
    }

    // ---- snow
    if (snow > 0.0) {
        float s = snowLayer(p, 46.0, 38.0, 1.0, snow * 0.6)
                + snowLayer(p + 17.0, 64.0, 55.0, 2.0, snow * 0.5) * 0.8;
        s = clamp(s, 0.0, 1.0);
        acc = vec4(snowColor.rgb * s, s) + acc * (1.0 - s);
    }

    fragColor = acc * qt_Opacity;
}
