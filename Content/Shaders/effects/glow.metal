// Cheap bloom: blurs the bright parts and adds them back.
// @param amount 0.6 0 3
// @param radius 0.012 0.001 0.05
// @param threshold 0.55 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float4 s = src.sample(linearClamp, in.uv);
    float aspect = f.resolution.x / f.resolution.y;
    float3 acc = 0;
    float total = 0;
    for (int ring = 1; ring <= 3; ring++) {
        for (int i = 0; i < 8; i++) {
            float a = (float(i) + float(ring) * 0.5) * M_PI_F / 4;
            float2 o = float2(cos(a) / aspect, sin(a)) * p.radius * float(ring);
            float3 c = src.sample(linearClamp, in.uv + o).rgb;
            float w = 1.0 / float(ring);
            acc += max(c - p.threshold, 0.0) * w;
            total += w;
        }
    }
    return float4(s.rgb + acc / total * p.amount * 3, s.a);
}
