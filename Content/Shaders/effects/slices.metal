// Slice displacement: horizontal strips slide by different amounts, like a torn scan.
// @param amount 0.05 0 0.5
// @param count 24 2 200
// @param speed 0.5 0 8
// @param jitter 1 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float row = floor(in.uv.y * p.count);
    float t = f.time * p.speed;
    float off = sin(row * 1.7 + t) * (1 - p.jitter) + (hash21(float2(row, floor(t * 4))) - 0.5) * 2 * p.jitter;
    float2 uv = in.uv + float2(off * p.amount, 0);
    return src.sample(linearRepeat, uv);
}
