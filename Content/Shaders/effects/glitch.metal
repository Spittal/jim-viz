// Block glitch: random rectangles jump sideways and split color, re-rolled rate × 2 times a
// second (once a beat at 120 BPM).
// @param amount 0.3 0 1
// @param blocks 12 2 64
// @param shift 0.08 0 0.5
// @param rate 1 0.25 8
// @param rgbSplit 0.01 0 0.08

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float tick = floor(f.time * p.rate * 2);
    float2 cell = floor(in.uv * float2(p.blocks * 0.5, p.blocks));
    float h = hash21(cell + tick * 7.13);
    float row = hash21(float2(cell.y, tick));
    float active = step(1 - p.amount * 0.5, h) * step(0.3, row);
    float2 uv = in.uv;
    uv.x += (hash21(cell * 1.7 + tick) - 0.5) * p.shift * active;
    float split = p.rgbSplit * active;
    float r = src.sample(linearClamp, uv + float2(split, 0)).r;
    float4 g = src.sample(linearClamp, uv);
    float b = src.sample(linearClamp, uv - float2(split, 0)).b;
    float3 c = float3(r, g.g, b);
    // Occasionally invert a block.
    if (hash21(cell + tick * 3.3) > 1 - p.amount * 0.02) c = 1 - c;
    return float4(c, g.a);
}
