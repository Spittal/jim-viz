// Video feedback: blends its own previous output back in, zoomed and rotated.
// The heart of the smeary, self-eating look. Effects before it in the chain get
// compounded on every loop; effects after it are applied once.
// @history self
// @param amount 0.85 0 0.99
// @param zoom 1.015 0.9 1.1
// @param rotate 0 -0.1 0.1
// @param driftX 0 -0.02 0.02
// @param driftY 0 -0.02 0.02
// @param mode 0 0 2 int
// mode 0 = trails behind geometry, 1 = brightest wins, 2 = additive

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 c = in.uv - 0.5;
    c.x *= aspect;
    c = rot2(p.rotate) * c / p.zoom;
    c.x /= aspect;
    float2 uv = c + 0.5 + float2(p.driftX, p.driftY);

    float4 s = src.sample(linearClamp, in.uv);
    float3 h = saturate(prev.sample(linearClamp, uv).rgb) * p.amount;
    float3 o;
    if (p.mode < 0.5) {
        o = mix(max(s.rgb, h), s.rgb, s.a);
    } else if (p.mode < 1.5) {
        o = max(s.rgb, h);
    } else {
        o = s.rgb + h * 0.5;
    }
    return float4(o, 1);
}
