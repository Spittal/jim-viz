// Edges: outlines wherever brightness changes, so every low-poly face boundary lights up.
// Colours come from a mapped palette, by edge strength or by edge direction; unmapped they
// run from black to white.
// @palette pal Palette
// @param amount 1.5 0 4
// @param width 1 0 6
// @param threshold 0.05 0 0.5
// @param fill 0 0 1
// @param direction 0 0 1
// width: in pixels. fill: how much of the picture stays under the edges. direction: 0 colours
// by strength, 1 by which way the edge runs.

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       texture2d<float> pal [[texture(2)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float2 px = p.width / f.resolution;
    float l[9];
    for (int i = 0; i < 9; i++) {
        float2 o = float2(i % 3 - 1, i / 3 - 1) * px;
        l[i] = luma(src.sample(linearClamp, in.uv + o).rgb);
    }
    // Sobel.
    float gx = (l[2] + 2 * l[5] + l[8]) - (l[0] + 2 * l[3] + l[6]);
    float gy = (l[6] + 2 * l[7] + l[8]) - (l[0] + 2 * l[1] + l[2]);
    float e = saturate((length(float2(gx, gy)) - p.threshold) * p.amount);
    float dir = atan2(gy, gx) / (2 * M_PI_F) + 0.5;
    float3 c = paletteClamp(pal, mix(e, dir, p.direction));
    float4 s = src.sample(linearClamp, in.uv);
    return float4(s.rgb * p.fill + c * e, s.a);
}
