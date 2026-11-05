// Cube: each face is a divisions × divisions grid of cells, two triangles each. inflate
// rounds it toward a sphere; faceSplit pushes the six faces apart along their axes; twist
// turns it around the vertical axis, more the higher up.
// @mesh cube
// @group Shape
// @param divisions 2 1 16 int mesh
// @param inflate 0 0 1
// @param faceSplit 0 0 3
// @param twist 0 -6 6

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Face (each of the six faces its own band), Height (bass at the bottom) or Random (per triangle).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Face,Height,Random

// @include _shared.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float3 c = v.position.xyz;
    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? (v.shape.w + 0.5) / 6 : mode == 1 ? saturate(c.y * 0.6 + 0.5) : v.position.w;

    float3 pos = mix(c, normalize(c), p.inflate) + v.shape.xyz * p.faceSplit;
    float3 n = v.smoothNormal.xyz, fn = normalize(mix(v.faceNormal.xyz, normalize(c), p.inflate));
    float2x2 r = rot2(pos.y * p.twist);
    pos.xz = r * pos.xz;
    n.xz = r * n.xz;
    fn.xz = r * fn.xz;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
