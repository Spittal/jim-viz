// Composite: blends a layer (map a Webcam, Video or Picture's video into Layer) with the
// picture so far. Comp lays the layer on top, Add sums the two, Difference subtracts one from
// the other, Burn darkens the picture through the layer (dark layer, darker picture).
// amount fades the layer's effect in. With Layer unmapped the picture passes through untouched.
// @video layer Layer
// @param mode 0 0 3 int Comp,Add,Difference,Burn
// @param amount 1 0 1

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       texture2d<float> layer [[texture(2)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float4 s = src.sample(linearClamp, in.uv);
    if (!hasInput(f, 2)) return s;
    float3 l = layer.sample(linearClamp, in.uv).rgb;
    int mode = int(p.mode + 0.5);
    float3 o;
    if (mode == 0) {
        o = l;
    } else if (mode == 1) {
        o = s.rgb + l;
    } else if (mode == 2) {
        o = abs(s.rgb - l);
    } else {
        o = saturate(1 - (1 - saturate(s.rgb)) / max(l, 1e-3));
    }
    return float4(mix(s.rgb, o, p.amount), s.a);
}
