// Gradient map: replaces colors with a palette by brightness, in hard bands.
// @palette pal Palette
// @param mix 1 0 1
// @param bands 0 0 16 int
// @param offset 0 0 1
// @param cycle 0 -1 1
// @param contrast 1 0.2 3

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       texture2d<float> pal [[texture(2)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float4 s = src.sample(linearClamp, in.uv);
    float l = saturate((luma(s.rgb) - 0.5) * p.contrast + 0.5);
    if (p.bands >= 1) l = floor(l * p.bands) / p.bands;
    float3 c = palette(pal, l * 0.98 + p.offset + f.time * p.cycle);
    return float4(mix(s.rgb, c, p.mix), s.a);
}
