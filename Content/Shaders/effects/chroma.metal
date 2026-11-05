// Chromatic aberration: splits red and blue outward from the center.
// @param amount 0.004 0 0.05
// @param radial 1 0 1
// @param angle 0 -3.15 3.15

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float2 c = in.uv - 0.5;
    float2 dir = mix(float2(cos(p.angle), sin(p.angle)), c * 2, p.radial) * p.amount;
    float r = src.sample(linearClamp, in.uv + dir).r;
    float4 g = src.sample(linearClamp, in.uv);
    float b = src.sample(linearClamp, in.uv - dir).b;
    return float4(r, g.g, b, g.a);
}
