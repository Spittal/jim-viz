// Shared by every shader. Jim Viz prepends this file, then a generated `Params` struct
// built from the shader's `// @param` lines, then the shader itself.
//
// Declare knobs at the top of a shader like this:
//   // @param amount 0.5 0 1        name, default, min, max
//   // @param steps 4 1 16 int      add "int" for whole numbers
// and read them as p.amount, p.steps.
//
// A shader gets nothing from other devices unless it declares an input and the scene maps an
// output into it. Declare inputs like this (they appear as sockets in the inspector):
//   // @video bgVideo Background      a picture, such as a Webcam's Video or Depth
//   // @spectrum spec Spectrum        Audio In's spectrum: read it with spectrum(spec, u)
//   // @palette pal Palette           a Palette's colours: read it with palette(pal, t)
// Inputs take texture slots in declaration order: generators from texture(0) up (bound in
// both the vertex and fragment stage), effects from texture(2) up.
// Effects also get texture(0) src = output of the previous effect and texture(1) prev = last
// frame's final output (or the effect's own last output if it has a `// @history self` line).
// hasInput(f, n) says whether the input at texture(n) is connected. Unconnected video and
// spectrum read 0; an unconnected palette is a grey ramp, black to white.
//
// The spectrum is 128 log-spaced bins from 30 Hz (u=0) to 16 kHz (u=1), values 0..1.
// Audio levels, hits and the clock reach shaders the same way as anything else: map an
// output (Audio In · Kick, Audio In · Pulse) onto a knob.

#include <metal_stdlib>
using namespace metal;

// Per-frame values. Layout must match FrameUniforms in MathUtil.swift.
struct Frame {
    float2 resolution;
    float time;       // seconds since start
    float dt;         // seconds since last frame
    float inputs;     // bit n set when the input at texture(n) is connected; use hasInput(f, n)
};

struct FXOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle. uv (0,0) is top-left.
vertex FXOut fx_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FXOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler linearRepeat(filter::linear, address::repeat);
constexpr sampler nearestClamp(filter::nearest, address::clamp_to_edge);

// Palette lookup. t wraps, so offsets cycle through the colors.
inline float3 palette(texture2d<float> pal, float t) {
    return pal.sample(linearRepeat, float2(fract(t) * 0.996 + 0.002, 0.5)).rgb;
}

// Palette lookup clamped to the ends.
inline float3 paletteClamp(texture2d<float> pal, float t) {
    return pal.sample(linearClamp, float2(saturate(t), 0.5)).rgb;
}

inline float spectrum(texture2d<float> spec, float u) {
    return spec.sample(linearClamp, float2(saturate(u), 0.5)).r;
}

inline bool hasInput(constant Frame& f, int slot) { return (int(f.inputs) >> slot) & 1; }

inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

inline float2x2 rot2(float a) {
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

inline float3x3 rotAxis(float3 axis, float a) {
    axis = normalize(axis);
    float s = sin(a), c = cos(a), oc = 1 - c;
    return float3x3(
        float3(oc * axis.x * axis.x + c,          oc * axis.x * axis.y + axis.z * s, oc * axis.z * axis.x - axis.y * s),
        float3(oc * axis.x * axis.y - axis.z * s, oc * axis.y * axis.y + c,          oc * axis.y * axis.z + axis.x * s),
        float3(oc * axis.z * axis.x + axis.y * s, oc * axis.y * axis.z - axis.x * s, oc * axis.z * axis.z + c));
}

inline float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float hash31(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

// Value noise in -1..1.
inline float noise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3 - 2 * f);
    float n000 = hash31(i), n100 = hash31(i + float3(1, 0, 0));
    float n010 = hash31(i + float3(0, 1, 0)), n110 = hash31(i + float3(1, 1, 0));
    float n001 = hash31(i + float3(0, 0, 1)), n101 = hash31(i + float3(1, 0, 1));
    float n011 = hash31(i + float3(0, 1, 1)), n111 = hash31(i + float3(1, 1, 1));
    float n = mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
                  mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
    return n * 2 - 1;
}

inline float fbm3(float3 x) {
    float v = 0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * noise3(x);
        x = x * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}
