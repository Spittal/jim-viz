// Polar: wraps the picture around the centre into rings and spokes (To Polar), or unrolls the
// rings around the centre into a strip (From Polar). Mirrored at the seam, so it never shows.
// @param mode 0 0 1 int To_Polar,From_Polar
// @param mix 1 0 1
// @param zoom 1 0.25 4
// @param repeat 1 1 8 int
// @param twist 0 -4 4
// @param spin 0 -2 2 rate
// repeat: copies around the circle. twist: turns the angle more the further out. spin: turns
// it all, in cycles a second.

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 uv;
    if (p.mode < 0.5) {
        float2 c = in.uv - 0.5;
        c.x *= aspect;
        float r = length(c) * 2 / p.zoom;
        float a = atan2(c.y, c.x) / (2 * M_PI_F) + 0.5;
        a = a * p.repeat + r * p.twist + p.spinPhase;
        uv = float2(1 - abs(fract(a) * 2 - 1), r);
    } else {
        float a = (in.uv.x * p.repeat + in.uv.y * p.twist + p.spinPhase) * 2 * M_PI_F;
        float r = in.uv.y * 0.5 * p.zoom;
        uv = 0.5 + float2(cos(a) / aspect, sin(a)) * r;
    }
    float4 s = src.sample(linearClamp, in.uv);
    return mix(s, src.sample(linearClamp, uv), p.mix);
}
