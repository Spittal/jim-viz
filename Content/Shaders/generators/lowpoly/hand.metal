// Hand: a fist with its pinky up. Each finger is a `sides`-sided tube of three phalanges,
// `segments` rings each. clench curls the thumb and the three middle fingers into the fist
// (0 an open hand, past 1 they dig in); pinkyCurl folds the pinky down into it (map a kick
// here to flick it); pinkyLength stretches the pinky; pinkyWiggle wobbles it on its own;
// splay fans the fingers apart; fingerWidth thickens every finger.
// @mesh hand
// @group Shape
// @param sides 6 3 12 int mesh
// @param segments 2 1 6 int mesh
// @param clench 1 0 1.3
// @param pinkyCurl 0 0 1
// @param pinkyLength 1 0 3
// @param pinkyWiggle 0 0 1
// @param splay 0 -1 3
// @param fingerWidth 1 0 3
// @param scale 1 0 4

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Finger (each finger its own band), Along (bass at the wrist, highs at the fingertips) or
// Random (per face). flick lifts each finger at its knuckle by its own band, up to that many degrees.
// @group Spectrum spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Finger,Along,Random
// @param flick 0 0 90

// @include _shared.metal
// @include _hand.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int mode = int(p.spectrumMode + 0.5);

    // Each joint's bend: the fist, the pinky's own curl and wiggle, and its band's flick.
    HandPose h;
    for (int i = 0; i < 5; i++) {
        h.bend[i] = handFist[i] * (i == 4 ? p.pinkyCurl : p.clench);
        if (p.flick > 0) h.bend[i].x -= spectrum(spec, i * 0.2) * p.flick;
        h.stretch[i] = 1;
    }
    float w = p.pinkyWiggle * 45;
    h.bend[4] += float3(noise3(float3(f.time * 1.7, 3.1, 0)), noise3(float3(f.time * 2.3, 7.9, 0)), 0) * w;
    h.stretch[4] = p.pinkyLength;
    h.splay = p.splay;
    h.width = p.fingerWidth;

    HandPoint hp = handPoint(v, h);
    float u = hp.finger == 5 ? (mode == 0 ? 1.0 : mode == 1 ? 0.0 : v.position.w)
                             : (mode == 0 ? (float(hp.finger) + 0.5) / 6 : mode == 1 ? 0.3 + hp.along / 3 * 0.7 : v.position.w);
    float3 pos = hp.pos;
    pos.y -= 0.1;
    return lowpolyVertex(geoPoint(pos, hp.normal, hp.faceN, u), v, iid, f, p, cam, spec);
}
