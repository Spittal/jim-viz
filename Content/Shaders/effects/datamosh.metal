// Datamosh: blocks that barely change hold on to their old pixels and keep sliding, so the
// picture melts into smeared, stuck blocks until fresh motion or a refresh cuts through.
// @history self
// @param amount 0.7 0 1
// @param blocks 24 4 96
// @param threshold 0.15 0 1
// @param drift 0.004 0 0.03
// @param refresh 0.5 0 8 rate
// amount: share of blocks allowed to hold. threshold: how much a block may change and still
// hold. drift: how far held blocks slide each frame. refresh: re-rolls the slide directions
// and which blocks hold, this many times a second.

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 grid = float2(p.blocks * aspect, p.blocks);
    float2 cell = floor(in.uv * grid);
    float2 centre = (cell + 0.5) / grid;
    float tick = floor(p.refreshPhase);

    float3 now = src.sample(linearClamp, centre).rgb;
    float3 was = prev.sample(linearClamp, centre).rgb;
    float change = length(now - was);
    if (isnan(change)) change = 1;

    float hold = step(hash21(cell + tick * 13.7), p.amount) * step(change, p.threshold);
    float2 mv = (float2(hash21(cell * 1.3 + tick), hash21(cell * 2.9 + tick + 5.1)) - 0.5) * 2 * p.drift;

    float4 s = src.sample(linearClamp, in.uv);
    float3 h = prev.sample(linearClamp, in.uv - mv).rgb;
    if (any(isnan(h))) h = s.rgb;
    return float4(mix(s.rgb, saturate(h), hold), s.a);
}
