// Echo: red, green and blue each leave their own trail, fading at different speeds and
// sliding off in different directions, so movement leaves rainbow ghosts.
// @history self
// @param amount 0.85 0 0.98
// @param spread 0.5 0 1
// @param offset 0.003 0 0.02
// @param angle 1.57 -3.15 3.15
// amount: how long trails last. spread: how much faster green and blue fade than red.
// offset: how far each channel's trail slides per frame (red one way, blue the other).

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 d = float2(cos(p.angle) / aspect, sin(p.angle)) * p.offset;
    float4 s = src.sample(linearClamp, in.uv);
    float3 h = float3(prev.sample(linearClamp, in.uv - d).r,
                      prev.sample(linearClamp, in.uv).g,
                      prev.sample(linearClamp, in.uv + d).b);
    if (any(isnan(h))) h = 0;
    float3 decay = p.amount * float3(1, 1 - p.spread * 0.4, 1 - p.spread * 0.8);
    return float4(max(s.rgb, saturate(h) * decay), s.a);
}
