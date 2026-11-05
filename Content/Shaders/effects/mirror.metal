// Mirror: reflects the image across the vertical and/or horizontal center line.
// @param horizontal 1 0 1 int Off,On
// @param vertical 0 0 1 int Off,On
// @param flip 0 0 1 int Off,On

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],
                       texture2d<float> prev [[texture(1)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float2 uv = in.uv;
    if (p.horizontal > 0.5) uv.x = 0.5 - abs(uv.x - 0.5);
    if (p.vertical > 0.5) uv.y = 0.5 - abs(uv.y - 0.5);
    if (p.flip > 0.5) uv = 1 - uv;
    return src.sample(linearClamp, uv);
}
