// Finishing pass: grain, scanlines, vignette and a little contrast.
// @param grain 0.06 0 0.5
// @param scanlines 0.15 0 1
// @param lineCount 360 60 1080
// @param vignette 0.4 0 1.5
// @param contrast 1.05 0.5 2
// @param flash 0 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float4 s = src.sample(linearClamp, in.uv);
    float3 c = (s.rgb - 0.5) * p.contrast + 0.5;
    float g = hash21(in.uv * f.resolution + fract(f.time) * 100) - 0.5;
    c += g * p.grain;
    c *= 1 - p.scanlines * (0.5 + 0.5 * sin(in.uv.y * p.lineCount * M_PI_F * 2));
    float2 v = in.uv - 0.5;
    c *= 1 - dot(v, v) * p.vignette * 2;
    c += p.flash;
    return float4(max(c, 0.0), s.a);
}
