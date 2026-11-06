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

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Finger (each finger its own band), Along (bass at the wrist, highs at the fingertips) or
// Random (per face). flick lifts each finger at its knuckle by its own band, up to that many degrees.
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Finger,Along,Random
// @param flick 0 0 90

// @include _shared.metal

// Thumb, index, middle, ring, pinky. Lengths must match MeshBuilder.handLengths in Render/Mesh.swift.
constant float3 handLen[5] = { float3(0.40, 0.28, 0.26), float3(0.42, 0.25, 0.22), float3(0.46, 0.28, 0.23),
                               float3(0.43, 0.26, 0.22), float3(0.36, 0.22, 0.20) };
// Where each finger leaves the palm.
constant float3 handBase[5] = { float3(0.18, -0.12, 0.33), float3(0, 0.5, 0.3), float3(0, 0.53, 0.1),
                                float3(0, 0.51, -0.1), float3(0, 0.46, -0.29) };
// Each joint's bend in a fist (clench 1), in degrees.
constant float3 handFist[5] = { float3(30, 40, 35), float3(80, 110, 75), float3(82, 110, 75),
                                float3(82, 110, 75), float3(82, 110, 75) };
// How far each finger leans sideways at splay 1, and the pinky's own lean out, in degrees.
constant float handSplay[5] = { 0, 10, 3, -4, -12 };
constant float pinkyLean = -8;

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int finger = int(fmod(v.shape.x, 10.0) + 0.5);
    int mode = int(p.spectrumMode + 0.5);
    float3 pos, n, fn;
    float u;

    if (finger == 5) {
        // The palm, as built.
        pos = v.position.xyz;
        n = v.smoothNormal.xyz;
        fn = v.faceNormal.xyz;
        u = mode == 0 ? 1.0 : mode == 1 ? 0.0 : v.position.w;
    } else {
        // The finger's frame: F along it when straight, B toward the palm (it bends that way),
        // L sideways.
        float3 F, B;
        if (finger == 0) {
            F = normalize(float3(0.5, 0.75, 0.45));
            float3 T = normalize(float3(0.15, 0.05, -1));
            B = normalize(T - dot(T, F) * F);
        } else {
            float lean = (handSplay[finger] * p.splay + (finger == 4 ? pinkyLean : 0)) * M_PI_F / 180;
            F = float3(0, cos(lean), sin(lean));
            B = float3(1, 0, 0);
        }
        float3 L = cross(F, B);

        // Each joint's bend: the fist, the pinky's own curl and wiggle, and its band's flick.
        float3 len = handLen[finger];
        float3 a = handFist[finger] * (finger == 4 ? p.pinkyCurl : p.clench);
        if (finger == 4) {
            len *= p.pinkyLength;
            float w = p.pinkyWiggle * 45;
            a += float3(noise3(float3(f.time * 1.7, 3.1, 0)), noise3(float3(f.time * 2.3, 7.9, 0)), 0) * w;
        }
        if (p.flick > 0) a.x -= spectrum(spec, finger * 0.2) * p.flick;
        a *= M_PI_F / 180;
        float3 th = float3(a.x, a.x + a.y, a.x + a.y + a.z);

        // Down the bent finger to this ring's centre.
        float s = v.shape.y;
        int j = min(int(s), 2);
        float t = s - float(j);
        float3 c = handBase[finger];
        for (int i = 0; i < j; i++) c += (cos(th[i]) * F + sin(th[i]) * B) * len[i];
        c += (cos(th[j]) * F + sin(th[j]) * B) * len[j] * t;

        // A ring on a joint sits halfway between its phalanges, widened so the tube doesn't pinch.
        float ring = th[j], widen = 1;
        if (t == 0) {
            ring = (th[j] + (j > 0 ? th[j - 1] : 0.0)) * 0.5;
            widen = 1 / max(cos(a[j] * 0.5), 0.6);
        }
        float3 N = -sin(ring) * F + cos(ring) * B;
        float3 off = v.shape.z * L + v.shape.w * N * widen;
        pos = c + off * p.fingerWidth;
        n = length(off) > 1e-5 ? normalize(off) : cos(th[2]) * F + sin(th[2]) * B;

        // The face's normal, built straight, turned with its phalanx.
        float tf = th[min(int(v.shape.x / 10 + 0.05), 2)];
        float3 lf = v.faceNormal.xyz;
        fn = lf.x * (cos(tf) * F + sin(tf) * B) + lf.y * (-sin(tf) * F + cos(tf) * B) + lf.z * L;

        u = mode == 0 ? (float(finger) + 0.5) / 6 : mode == 1 ? 0.3 + s / 3 * 0.7 : v.position.w;
    }
    pos.y -= 0.1;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
