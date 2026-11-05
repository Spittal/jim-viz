// Kaleidoscope: folds the image into mirrored wedges around the center.
// @param segments 6 2 24 int
// @param rotate 0 -3.15 3.15
// @param spin 0.1 -2 2
// @param zoom 1 0.2 4
// @param mix 1 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 c = in.uv - 0.5;
    c.x *= aspect;
    float r = length(c) / p.zoom;
    float a = atan2(c.y, c.x) + p.rotate + f.time * p.spin;
    float wedge = 2 * M_PI_F / max(p.segments, 2.0);
    a = fmod(a, wedge);
    if (a < 0) a += wedge;
    a = abs(a - wedge * 0.5);
    float2 k = float2(cos(a), sin(a)) * r;
    k.x /= aspect;
    float4 kal = src.sample(linearClamp, k + 0.5);
    return mix(src.sample(linearClamp, in.uv), kal, p.mix);
}
