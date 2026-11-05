// Pixelate and posterize: chunky pixels and reduced color depth.
// @param size 1 1 64
// @param levels 0 0 16 int
// @param dither 0 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float2 px = max(p.size, 1.0) / f.resolution;
    float2 uv = (floor(in.uv / px) + 0.5) * px;
    float4 s = src.sample(nearestClamp, uv);
    float3 c = s.rgb;
    if (p.levels >= 1) {
        // 4x4 ordered dither before quantizing.
        int2 ip = int2(in.position.xy / max(p.size, 1.0)) & 3;
        const float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
        float d = (bayer[ip.y * 4 + ip.x] / 16 - 0.5) * p.dither / p.levels;
        c = floor((c + d) * p.levels + 0.5) / p.levels;
    }
    return float4(c, s.a);
}
