// Ridges: a stack of lines, one behind the other, each tracing the spectrum, after the stacked
// pulsar plot. The front line is the spectrum now and each line behind it is a moment older,
// so peaks travel back through the stack. Every line is the top edge of a curtain that hides
// the lines behind it. The front line is nearest a camera on +x (Static · Front), bass on its left.
// @mesh ridges

// Inputs. Spectrum raises the lines (map Audio In's Spectrum into it); unmapped, they lie flat.
// Palette colours the lines, the curtains and the background (map a Palette's Colours into it).
// @palette pal Palette
// @spectrum spec Spectrum

// Shape: `lines` lines of `segments` straight pieces each, width across. The stack climbs by
// rise and goes back by recede from its front line to its last. drop is how far each curtain
// hangs below its line: at 0 there's nothing to draw.
// @group Shape
// @param lines 40 1 128 int mesh
// @param segments 64 2 256 int mesh
// @param width 6 0 30
// @param rise 5 0 30
// @param recede 2 0 30
// @param drop 1.5 0 10
// @param scale 1 0 4

// Surface: noise roughens every line on its own. window flattens the ends of the lines, so
// the peaks gather in the middle.
// @group Surface
// @param noiseAmount 0 0 2
// @param noiseScale 1.5 0 8
// @param noiseSpeed 0.25 0 4 rate
// @param window 0.5 0 1

// Look: line is the lines' thickness, in pixels at 1080p. lineColor and fillColor are where
// along the palette the lines and curtains take their colour; heat shifts both along it where
// a line is raised. fill shows the curtains: at 0 they are the colour of the background.
// @group Look
// @param line 2 0 16
// @param lineColor 1 0 1
// @param fill 0 0 1
// @param fillColor 0.4 0 1
// @param heat 0 -1 1
// @param fog 0.03 0 0.5
// @param bgGlow 0.5 0 2

// Audio: spectrum is how far the spectrum raises the lines. spectrumMode lays it out Across
// (bass on the left) or Mirror (bass in the middle). history is how many seconds old the last
// line is; at 0 every line shows the spectrum now.
// @group Spectrum spec
// @param spectrum 1 0 4
// @param spectrumMode 0 0 1 int Across,Mirror
// @param history 1.5 0 4

// Layout must match MeshVertex in Render/Mesh.swift.
struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
    float4 shape;        // see MeshBuilder.ridges in Render/Mesh.swift
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

struct RidgeOut {
    float4 position [[position]];
    float3 world;
    float level;              // how far the line is raised here, 0..1
    float hang;               // 1 on the ridge, 0 at the curtain's foot
    float2 a [[flat]];        // this quad's piece of the line, in pixels
    float2 b [[flat]];
};

// How far the line `line` (0 the front, 1 the last) is raised at u across it, 0..1 of the most it can be.
inline float ridgeLevel(float u, float line, constant Params& p, texture2d<float> spec) {
    float su = int(p.spectrumMode + 0.5) == 1 ? abs(u * 2 - 1) : u;
    float h = p.spectrum > 0 ? spectrumAt(spec, su * 0.85, line * p.history) * p.spectrum : 0;
    if (p.noiseAmount > 0) {
        float n = fbm3(float3(u * p.noiseScale * 6, line * 53.0, p.noiseSpeedPhase));
        h += n * n * 4 * p.noiseAmount;
    }
    float flat = p.window * 0.3;
    h *= p.window > 0 ? smoothstep(flat, flat + 0.15, min(u, 1 - u)) : 1.0;
    return h;
}

// A point on line `line`, raised by h.
inline float3 ridgePoint(float u, float line, float h, constant Params& p) {
    return float3((0.5 - line) * p.recede, (line - 0.5) * p.rise + h, (0.5 - u) * p.width) * p.scale;
}

// A clip-space point in pixels, or far off screen when it is behind the camera.
inline float2 toPixels(float4 clip, constant Frame& f) {
    if (clip.w < 1e-4) return float2(-1e6);
    return (clip.xy / clip.w * float2(0.5, -0.5) + 0.5) * f.resolution;
}

vertex RidgeOut gen_vertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant Frame& f [[buffer(1)]],
                           constant Params& p [[buffer(2)]],
                           constant Camera& cam [[buffer(3)]],
                           texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float u = v.shape.x, line = v.shape.y, other = v.shape.w;
    float h = ridgeLevel(u, line, p, spec), hOther = ridgeLevel(other, line, p, spec);
    float3 ridge = ridgePoint(u, line, h, p);
    float3 pos = v.shape.z > 0.5 ? ridge : ridgePoint(u, line, -p.drop, p);

    RidgeOut o;
    o.world = pos;
    o.position = cam.viewProj * float4(pos, 1);
    o.level = saturate(h / max(p.spectrum + p.noiseAmount, 1e-3));
    o.hang = v.shape.z;
    o.a = toPixels(cam.viewProj * float4(ridge, 1), f);
    o.b = toPixels(cam.viewProj * float4(ridgePoint(other, line, hOther, p), 1), f);
    return o;
}

// The background at uv: a soft glow in the palette's dark end.
inline float3 backdrop(float2 uv, texture2d<float> pal, constant Frame& f, constant Params& p) {
    float2 c = uv - 0.5;
    c.x *= f.resolution.x / f.resolution.y;
    float g = saturate(1 - length(c) * 1.1);
    float n = fbm3(float3(c * 2.5, f.time * 0.05));
    return paletteClamp(pal, 0.04 + 0.12 * (n * 0.5 + 0.5)) * p.bgGlow * (0.15 + 0.6 * g * g);
}

// Alpha marks what's drawn: the lines, and the curtains as far as fill shows them. A curtain at
// fill 0 is background, so feedback trails show on it.
fragment float4 gen_fragment(RidgeOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    float3 bg = backdrop(in.position.xy / f.resolution, pal, f, p);
    float fade = exp(-length(cam.position.xyz - in.world) * p.fog);

    float3 face = paletteClamp(pal, p.fillColor + p.heat * in.level) * (0.25 + 0.75 * in.hang);
    float fill = p.fill * fade;
    float3 col = mix(bg, face, fill);

    // The line: within its thickness of this quad's piece of the ridge.
    float2 px = in.position.xy, ab = in.b - in.a;
    float d = length(px - in.a - ab * saturate(dot(px - in.a, ab) / max(dot(ab, ab), 1e-6)));
    float thick = p.line * f.resolution.y / 1080;
    float on = saturate(thick - d + 0.5) * saturate(thick * 2) * fade;
    col = mix(col, paletteClamp(pal, p.lineColor + p.heat * in.level) * 1.4, on);
    return float4(col, max(on, fill));
}

// Drawn behind the mesh. Alpha 0 marks background so feedback can trail behind geometry.
fragment float4 gen_background(FXOut in [[stage_in]],
                               texture2d<float> pal [[texture(0)]],
                               constant Frame& f [[buffer(0)]],
                               constant Params& p [[buffer(1)]]) {
    return float4(backdrop(in.uv, pal, f, p), 0);
}
