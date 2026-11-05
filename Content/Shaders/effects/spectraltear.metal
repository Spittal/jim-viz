// Spectral tear: the picture is cut into strips, and each strip is pulled sideways by its own
// band of a mapped spectrum, splitting colour as it goes. Unmapped, nothing moves.
// @spectrum spec Spectrum
// @param amount 0.12 0 0.5
// @param strips 48 4 256
// @param axis 0 0 1 int Rows,Columns
// @param centre 1 0 1 int Off,On
// @param split 0.3 0 1
// @param gain 1 0 4
// centre: lows in the middle and highs at both edges, instead of lows at one edge. split: how
// far red and blue pull apart from green.

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       texture2d<float> spec [[texture(2)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    bool cols = p.axis > 0.5;
    float along = cols ? in.uv.x : in.uv.y;
    float strip = floor(along * p.strips);
    float u = (strip + 0.5) / p.strips;
    if (p.centre > 0.5) u = abs(u * 2 - 1);
    float level = saturate(spectrum(spec, u) * p.gain);
    float sgn = hash11(strip * 7.31) > 0.5 ? 1 : -1;
    float off = level * p.amount * sgn;
    float2 d = cols ? float2(0, off) : float2(off, 0);
    float r = src.sample(linearRepeat, in.uv + d * (1 + p.split)).r;
    float4 g = src.sample(linearRepeat, in.uv + d);
    float b = src.sample(linearRepeat, in.uv + d * (1 - p.split)).b;
    return float4(r, g.g, b, g.a);
}
