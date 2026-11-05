// Sphere: an icosphere. detail subdivides it (each step makes four triangles of every one);
// squash flattens or stretches it top to bottom; twist turns it around the vertical axis,
// more the higher up.
// @mesh sphere
// @group Shape
// @param detail 2 0 5 int mesh
// @param squash 1 0 4
// @param twist 0 -6 6

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Height (bass at the bottom), Random (per face) or Angle (around the vertical axis).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 1 0 2 int Height,Random,Angle

// @include _shared.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float3 pos = v.position.xyz;
    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? saturate(pos.y * 0.5 + 0.5) : mode == 1 ? v.position.w : abs(atan2(pos.z, pos.x)) / M_PI_F;

    pos.y *= p.squash;
    float2x2 r = rot2(pos.y * p.twist);
    pos.xz = r * pos.xz;
    float3 n = v.smoothNormal.xyz, fn = v.faceNormal.xyz;
    n.xz = r * n.xz;
    fn.xz = r * fn.xz;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
