// Shared by the geos that draw MeshBuilder.hand's mesh (Hand, and Simulation's Jenga): where the
// fingers leave the palm, how long they are and how a vertex follows their bends. The includer
// declares MeshVertex. Files starting with _ are shared code, not geos.

// Thumb, index, middle, ring, pinky. Lengths must match MeshBuilder.handLengths in Render/Mesh.swift.
constant float3 handLen[5] = { float3(0.40, 0.28, 0.26), float3(0.42, 0.25, 0.22), float3(0.46, 0.28, 0.23),
                               float3(0.43, 0.26, 0.22), float3(0.36, 0.22, 0.20) };
// Where each finger leaves the palm.
constant float3 handBase[5] = { float3(0.18, -0.12, 0.33), float3(0, 0.5, 0.3), float3(0, 0.53, 0.1),
                                float3(0, 0.51, -0.1), float3(0, 0.46, -0.29) };
// Each joint's bend in a fist, in degrees.
constant float3 handFist[5] = { float3(30, 40, 35), float3(80, 110, 75), float3(82, 110, 75),
                                float3(82, 110, 75), float3(82, 110, 75) };
// How far each finger leans sideways at splay 1, and the pinky's own lean out, in degrees.
constant float handSplay[5] = { 0, 10, 3, -4, -12 };
constant float pinkyLean = -8;

// A pose: each finger's three joint bends in degrees (0 straight, handFist a fist), how far
// each finger's length stretches, how far they fan out (splay) and how thick they are.
struct HandPose {
    float3 bend[5];
    float stretch[5];
    float splay;
    float width;
};

struct HandPoint {
    float3 pos;
    float3 normal;     // smooth, for displacement
    float3 faceN;
    int finger;        // 0 thumb … 4 pinky, 5 the palm
    float along;       // along the finger 0...3 (3 the tip); 0 on the palm
};

// A vertex of the hand mesh, posed, in the hand's own frame: the palm runs up y from the wrist,
// the fingers carry on up and curl toward +x, the thumb is on the +z side.
inline HandPoint handPoint(MeshVertex v, HandPose h) {
    HandPoint o;
    o.finger = int(fmod(v.shape.x, 10.0) + 0.5);
    o.along = 0;
    if (o.finger == 5) {
        // The palm, as built.
        o.pos = v.position.xyz;
        o.normal = v.smoothNormal.xyz;
        o.faceN = v.faceNormal.xyz;
        return o;
    }
    int finger = o.finger;
    // The finger's frame: F along it when straight, B toward the palm (it bends that way),
    // L sideways.
    float3 F, B;
    if (finger == 0) {
        F = normalize(float3(0.5, 0.75, 0.45));
        float3 T = normalize(float3(0.15, 0.05, -1));
        B = normalize(T - dot(T, F) * F);
    } else {
        float lean = (handSplay[finger] * h.splay + (finger == 4 ? pinkyLean : 0)) * M_PI_F / 180;
        F = float3(0, cos(lean), sin(lean));
        B = float3(1, 0, 0);
    }
    float3 L = cross(F, B);

    float3 len = handLen[finger] * h.stretch[finger];
    float3 a = h.bend[finger] * M_PI_F / 180;
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
    o.pos = c + off * h.width;
    o.normal = length(off) > 1e-5 ? normalize(off) : cos(th[2]) * F + sin(th[2]) * B;

    // The face's normal, built straight, turned with its phalanx.
    float tf = th[min(int(v.shape.x / 10 + 0.05), 2)];
    float3 lf = v.faceNormal.xyz;
    o.faceN = lf.x * (cos(tf) * F + sin(tf) * B) + lf.y * (-sin(tf) * F + cos(tf) * B) + lf.z * L;
    o.along = s;
    return o;
}
