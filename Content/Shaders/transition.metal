#include <metal_stdlib>
using namespace metal;

struct FXOut {
    float4 position [[position]];
    float2 uv;
};

vertex FXOut transition_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FXOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

fragment float4 transition_fragment(FXOut in [[stage_in]],
                                    texture2d<float> fromTex [[texture(0)]],
                                    texture2d<float> toTex [[texture(1)]],
                                    constant float& progress [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 a = fromTex.sample(s, in.uv);
    float4 b = toTex.sample(s, in.uv);
    return mix(a, b, saturate(progress));
}
