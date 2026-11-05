// Torus: a ring of `rings` segments, its tube `sides`-sided. thickness is the tube's radius.
// twist turns the tube's cross-section as it goes round, by that many sides per lap (whole
// numbers close up cleanly; anything else leaves a seam). wave ripples the ring up and down
// in `lobes` bumps that travel round at waveSpeed.
// @mesh torus
// @group Shape
// @param rings 12 3 64 int mesh
// @param sides 8 3 32 int mesh
// @param thickness 0.42 0.02 1.5
// @param twist 0 -8 8
// @param wave 0 0 1
// @param lobes 3 1 12 int
// @param waveSpeed 1 -4 4

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Ring (round the ring), Tube (round the tube) or Random (per face).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 2 0 2 int Ring,Tube,Random

// @include _shared.metal

// The torus point at (u, w), both 0..1 round the ring and the tube, and its tube normal.
inline float3 torusPoint(float2 uw, constant Frame& f, constant Params& p, thread float3& n) {
    float u = uw.x * 2 * M_PI_F;
    float w = (uw.y + uw.x * p.twist / max(p.sides, 1.0)) * 2 * M_PI_F;
    n = float3(cos(u) * cos(w), sin(w), sin(u) * cos(w));
    float y = p.wave * sin(u * p.lobes + f.time * p.waveSpeed);
    return float3(cos(u), y, sin(u)) + n * p.thickness;
}

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float3 n, fn;
    float3 pos = torusPoint(v.shape.xy, f, p, n);
    torusPoint(v.shape.zw, f, p, fn);
    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? abs(v.shape.x * 2 - 1) : mode == 1 ? abs(v.shape.y * 2 - 1) : v.position.w;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
