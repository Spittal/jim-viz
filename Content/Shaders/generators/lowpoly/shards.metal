// Shards: a cloud of `count` four-faced crystals pointing outward. size scales each shard
// about its own centre; length stretches their tips outward; radius spreads the cloud;
// shardSpin turns every shard on its own axis.
// @mesh shards
// @group Shape
// @param count 216 8 1500 int mesh
// @param size 1 0 3
// @param length 2.5 0 8
// @param radius 1 0 4
// @param shardSpin 0 -4 4 rate
// @param scale 1 0 4

// Audio: Spectrum pushes shards out. spectrumMode picks the frequency each reads:
// Distance (bass at the centre), Random (per face) or Angle (around the vertical axis).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 1 0 2 int Distance,Random,Angle

// @include _shared.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float3 c = v.shape.xyz, dir = normalize(c);
    float3 off = v.position.xyz - c + dir * v.shape.w * p.length;
    float sr = hash31(c * 7.1 + 0.3);
    float3 axis = normalize(float3(hash11(sr * 3.1) - 0.5, hash11(sr * 5.7) - 0.5, hash11(sr * 9.3) - 0.5) + 1e-3);
    float3x3 r = rotAxis(axis, p.shardSpinPhase * (0.5 + sr));
    float3 pos = c * p.radius + r * off * p.size;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? saturate((length(c) - 0.4) / 1.4) : mode == 1 ? v.position.w : abs(atan2(c.z, c.x)) / M_PI_F;
    return lowpolyVertex(geoPoint(pos, dir, r * v.faceNormal.xyz, u), v, iid, f, p, cam, spec);
}
