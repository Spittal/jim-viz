// Noise-driven UV displacement: liquid, melting distortion.
// @param amount 0.02 0 0.2
// @param scale 3 0.2 20
// @param speed 0.3 0 4
// @param swirl 0 -2 2

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float2 uv = in.uv;
    float t = f.time * p.speed;
    float2 d = float2(fbm3(float3(uv * p.scale, t)), fbm3(float3(uv * p.scale + 9.3, t)));
    float2 c = uv - 0.5;
    c = rot2(p.swirl * (0.5 - length(c))) * c;
    uv = c + 0.5 + d * p.amount;
    return src.sample(linearClamp, uv);
}
