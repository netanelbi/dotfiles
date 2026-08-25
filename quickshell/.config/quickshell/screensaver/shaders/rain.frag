#version 440
// Digital rain, Catppuccin Mocha. Drawn entirely on the GPU: no glyph atlas,
// no per-drop QML objects -- one fullscreen quad, one pass.
//
// Qt6 does not read .frag at runtime; this is compiled to rain.frag.qsb with
//     /usr/lib/qt6/bin/qsb --glsl 100es,120,150 --hlsl 50 --msl 12
//         -o rain.frag.qsb rain.frag
// and the .qsb is what ships. Rebuild it after every edit here.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float time;         // seconds since the screensaver opened
    vec2  resolution;   // pixels, for aspect correction
    float fade;         // 0..1 master fade, drives the entrance
    vec2  center;       // where the art currently sits, in 0..1 uv
};

// Cheap hash. Deterministic per column/cell, no texture lookup.
float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 uv = qt_TexCoord0;

    // Columns are a fixed pixel width, so the rain does not stretch when the
    // shader runs on monitors of different widths.
    float colW    = 14.0;
    float cols    = max(1.0, floor(resolution.x / colW));
    float colIdx  = floor(uv.x * cols);
    float colSeed = hash(vec2(colIdx, 7.0));

    // Each column falls at its own speed and starts at its own offset.
    float speed  = mix(0.08, 0.34, hash(vec2(colIdx, 19.0)));
    float head   = fract(colSeed + time * speed);

    // Distance below the head, wrapped, so the trail follows it down.
    float d = fract(uv.y - head + 1.0);

    // The trail: bright at the head, fading over `len`.
    float len   = mix(0.18, 0.5, hash(vec2(colIdx, 31.0)));
    float trail = 1.0 - smoothstep(0.0, len, d);
    trail = pow(trail, 2.2);

    // Cell flicker -- the reason it reads as glyphs rather than smooth streaks.
    float rowH   = 20.0;
    float rowIdx = floor(uv.y * resolution.y / rowH);
    float cell   = hash(vec2(colIdx, rowIdx + floor(time * 6.0)));
    float glyph  = step(0.35, cell);

    // Gaps around each cell, so a column reads as a stack of separate marks
    // rather than one continuous streak.
    vec2 cellUV = fract(vec2(uv.x * cols, uv.y * resolution.y / rowH));
    glyph *= step(0.14, cellUV.x) * step(cellUV.x, 0.86)
           * step(0.12, cellUV.y) * step(cellUV.y, 0.88);

    // The head itself stays lit, so drops keep a sharp leading edge.
    float headGlow = 1.0 - smoothstep(0.0, 0.035, d);

    float lum = trail * mix(0.35, 1.0, glyph) + headGlow * 0.9;

    // Mauve body -> lavender head, on crust. Same palette as the bar.
    vec3 crust    = vec3(0.067, 0.067, 0.106);
    vec3 mauve    = vec3(0.796, 0.651, 0.969);
    vec3 lavender = vec3(0.706, 0.745, 0.996);
    vec3 col = mix(mauve, lavender, headGlow);

    // Two falloffs, and they are centred on different things on purpose.
    vec2 aspect = vec2(resolution.x / resolution.y, 1.0);

    // The clearing tracks the art. It is the quiet patch the wordmark sits in,
    // so it has to drift with it -- pinned to screen centre it stays put while
    // the art floats out of it, and the hole reads as a second box sliding
    // around inside the first.
    float rad = length((uv - center) * aspect);
    float clearing = 1.0 - smoothstep(0.0, 0.46, rad);
    lum *= mix(1.0, 0.12, clearing);

    // The vignette frames the screen, so this one stays screen-centred.
    float edge = length((uv - 0.5) * aspect);
    lum *= mix(1.0, 0.45, smoothstep(0.55, 0.95, edge));

    fragColor = vec4(mix(crust, col, clamp(lum, 0.0, 1.0)) * fade, 1.0) * qt_Opacity;
}
