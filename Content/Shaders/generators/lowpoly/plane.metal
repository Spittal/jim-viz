// Plane: a flat sheet, width × height, lying face up. density is cells per unit, so a bigger
// sheet gets more cells; jitter nudges the inner corners off the grid for an irregular
// triangulation. The camera's front (+x) looks at it the way the Front video mode and Depth
// project onto it.
// @mesh plane
// @group Shape
// @param width 10 1 50 mesh
// @param height 10 1 50 mesh
// @param density 3.2 0.5 12 mesh
// @param jitter 0.7 0 1

// Audio: Spectrum pushes vertices up. spectrumMode picks the frequency each vertex reads:
// Rings (bass in the middle), Across (bass on the left), Angle (around the middle) or Random (per face).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 3 int Rings,Across,Angle,Random

// @include _shared.metal

// Depth: map a Webcam's Depth output into Depth to raise the sheet where things are near the
// camera. It's projected across the sheet edge-to-edge. depth is how far near things rise;
// depthCut hides faces stretched across a depth edge, so a person stands free of the wall
// behind instead of being joined to it by a skirt.
// @video depthVideo Depth
// @group Depth depthVideo
// @param depth 2 0 6
// @param depthCut 0.5 0 1

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]],
                         texture2d<float> depthVid [[texture(3)]]) {
    MeshVertex v = verts[vid];
    // Position on the sheet, -0.5..0.5 across (z) and deep (x).
    float2 s = v.shape.xy + v.shape.zw * p.jitter;
    float3 pos = float3(s.x * p.height, 0, s.y * p.width);
    float2 fuv = float2(0.5 - s.y, 0.5 + s.x);
    float3 up = float3(0, 1, 0);

    bool depthOn = hasInput(f, 3) && p.depth > 0;
    if (depthOn) pos.y += luma(depthVid.sample(linearClamp, fuv, level(0)).rgb) * p.depth;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? saturate(length(s) * 2) : mode == 1 ? 0.5 - s.y
            : mode == 2 ? abs(atan2(s.y, s.x)) / M_PI_F : v.position.w;
    GeoPoint g = geoPoint(pos, up, up, u);
    g.frontUV = fuv;
    g.depthPos = pos;
    g.cut = depthOn ? p.depthCut : 0;
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
