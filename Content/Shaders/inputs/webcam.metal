// Webcam processing: turns the raw camera frame into the Webcam input's video output.
// texture(0) cam = latest camera frame (any size; it's cropped to fill 16:9).
// Every knob is mappable, so the feed can zoom on the kick or warp with an LFO.
//
// webcam_depth draws the Depth output: depth estimated from the camera image (white = near),
// framed by the same Frame and Warp knobs so it lines up with the video. It only runs while
// Depth is mapped somewhere.

// @group Frame
// @param zoom 1 0.5 4
// @param rotate 0 -180 180
// @param panX 0 -1 1
// @param panY 0 -1 1
// @param mirror 1 0 3 int Off,Flip,Fold,Quad

// @group Warp
// @param warp 0 0 1
// @param warpScale 3 0 12
// @param warpSpeed 0.5 0 4 rate

// @group Color
// @param exposure 0 -2 2
// @param contrast 1 0 3
// @param saturation 1 0 2
// @param edges 0 0 1
// @param posterize 0 0 1

// @group Output
// @param bg 0 0 1

// @group Depth
// @param depthSmooth 0.7 0 0.97
// @param depthContrast 1.3 0 4
// @param depthFloor 0.1 0 0.9

// Where an output pixel samples the camera image: mirror, zoom, rotate, pan, warp, then
// crop to fill 16:9. camAspect is the camera's width / height.
inline float2 framedUV(float2 uv, constant Frame& f, constant Params& p, float camAspect) {
    // Mirror: Flip is the selfie view, Fold mirrors the left half onto the right, Quad folds both ways.
    int m = int(p.mirror + 0.5);
    if (m == 1) uv.x = 1 - uv.x;
    if (m >= 2) uv.x = uv.x < 0.5 ? uv.x : 1 - uv.x;
    if (m == 3) uv.y = uv.y < 0.5 ? uv.y : 1 - uv.y;

    // Zoom, rotate and pan around the centre, in 16:9 space so rotation doesn't squash.
    float aspect = 16.0 / 9.0;
    float2 c = (uv - 0.5) * float2(aspect, 1);
    c = rot2(p.rotate * M_PI_F / 180) * c / max(p.zoom, 0.01);
    c += float2(p.panX * aspect, p.panY) * 0.5;

    // Warp: a slow, swirling displacement field.
    if (p.warp > 0) {
        float t = p.warpSpeedPhase;
        float2 q = c * p.warpScale;
        float2 d = float2(fbm3(float3(q, t)), fbm3(float3(q + 7.3, t + 3.1)));
        c += d * p.warp * 0.35;
    }
    uv = c / float2(aspect, 1) + 0.5;

    // Crop the camera image to fill 16:9.
    float2 s = camAspect > aspect ? float2(aspect / camAspect, 1) : float2(1, camAspect / aspect);
    return (uv - 0.5) * s + 0.5;
}

inline float aspectOf(texture2d<float> t) { return float(t.get_width()) / max(float(t.get_height()), 1.0); }

fragment float4 webcam(FXOut in [[stage_in]],
                       texture2d<float> cam [[texture(0)]],
                       constant Frame& f [[buffer(0)]],
                       constant Params& p [[buffer(1)]]) {
    float aspect = 16.0 / 9.0;
    float camAspect = aspectOf(cam);
    float2 s = camAspect > aspect ? float2(aspect / camAspect, 1) : float2(1, camAspect / aspect);
    float2 cuv = framedUV(in.uv, f, p, camAspect);
    constexpr sampler mirrorS(filter::linear, address::mirrored_repeat);
    float3 col = cam.sample(mirrorS, cuv).rgb;

    // Edges: Sobel on luminance, mixed over the image.
    if (p.edges > 0) {
        float2 px = s / float2(cam.get_width(), cam.get_height()) * 1.5;
        float tl = luma(cam.sample(mirrorS, cuv + px * float2(-1, -1)).rgb);
        float tr = luma(cam.sample(mirrorS, cuv + px * float2( 1, -1)).rgb);
        float bl = luma(cam.sample(mirrorS, cuv + px * float2(-1,  1)).rgb);
        float br = luma(cam.sample(mirrorS, cuv + px * float2( 1,  1)).rgb);
        float l  = luma(cam.sample(mirrorS, cuv + px * float2(-1,  0)).rgb);
        float r  = luma(cam.sample(mirrorS, cuv + px * float2( 1,  0)).rgb);
        float t  = luma(cam.sample(mirrorS, cuv + px * float2( 0, -1)).rgb);
        float b  = luma(cam.sample(mirrorS, cuv + px * float2( 0,  1)).rgb);
        float gx = (tr + 2 * r + br) - (tl + 2 * l + bl);
        float gy = (bl + 2 * b + br) - (tl + 2 * t + tr);
        float e = saturate(length(float2(gx, gy)) * 2);
        col = mix(col, float3(e), p.edges);
    }

    col *= exp2(p.exposure);
    col = (col - 0.5) * p.contrast + 0.5;
    col = mix(float3(luma(col)), col, p.saturation);
    if (p.posterize > 0) {
        float levels = mix(16.0, 2.0, p.posterize);
        col = floor(saturate(col) * levels + 0.5) / levels;
    }
    return float4(max(col, 0.0), 1);
}

// texture(0) raw = the model's latest depth for the whole camera frame (same aspect as the
// camera), texture(1) prev = this output last frame.
fragment float4 webcam_depth(FXOut in [[stage_in]],
                             texture2d<float> raw [[texture(0)]],
                             texture2d<float> prev [[texture(1)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]]) {
    constexpr sampler mirrorS(filter::linear, address::mirrored_repeat);
    float d = raw.sample(mirrorS, framedUV(in.uv, f, p, aspectOf(raw))).r;
    d = saturate((d - p.depthFloor) / max(1 - p.depthFloor, 1e-3));
    d = pow(d, p.depthContrast);
    // Ease toward the new depth. Scaled by frame time so it feels the same at any frame rate.
    float keep = pow(saturate(p.depthSmooth), f.dt * 60);
    float old = prev.sample(mirrorS, in.uv).r;
    // History starts as uninitialized memory; don't let a NaN in it stick forever.
    if (isfinite(old)) d = mix(d, old, keep);
    return float4(d, d, d, 1);
}
