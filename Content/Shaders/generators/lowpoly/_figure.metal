// Shared by the posed figures (Dancer, Shrek): a pose, a keyed routine of them, and the
// rotations that build a figure from one.

// A pose, in degrees. The front is +x and up is +y; facing the front, its right is +z.
// A limb's two angles are its swing (0 hangs down, 90 points the way the body faces, 180 up,
// -90 behind) and how far it is raised out to its own side (negative crosses the body). Arms
// and legs are set against the way the body faces, not its lean, so 90 is always level.
// The feet find the floor by themselves: the lower one stands on it.
struct Pose {
    float3 body;     // turned to its left, leaning forward, leaning to its right
    float3 spine;    // the chest on the hips: twisted to its left, bent forward, bent to its right
    float2 head;     // turned to its left, nodding
    float2 shift;    // the hips moved over the floor: toward the front, toward +z
    float4 arm[2];   // right, left: upper arm swing, out; forearm swing, out
    float4 leg[2];   // right, left: thigh swing, out; shin swing, out
};

inline Pose mixPose(Pose a, Pose b, float t) {
    Pose p;
    p.body = mix(a.body, b.body, t);
    p.spine = mix(a.spine, b.spine, t);
    p.head = mix(a.head, b.head, t);
    p.shift = mix(a.shift, b.shift, t);
    for (int i = 0; i < 2; i++) {
        p.arm[i] = mix(a.arm[i], b.arm[i], t);
        p.leg[i] = mix(a.leg[i], b.leg[i], t);
    }
    return p;
}

// A routine's pose at a beat. Its keys are (the beat it arrives on, the pose); the same pose
// twice is a hold, and it loops after danceBeats. snap holds each pose, then pops to the next.
inline Pose danceAt(constant Pose* poses, constant float2* danceKeys, int danceKeyCount, float danceBeats, float beat, float snap) {
    float b = beat - floor(beat / danceBeats) * danceBeats;
    int i = 0;
    for (int k = 1; k < danceKeyCount; k++) { if (danceKeys[k].x <= b) i = k; }
    int j = (i + 1) % danceKeyCount;
    float from = danceKeys[i].x, to = j == 0 ? danceBeats : danceKeys[j].x;
    float t = smoothstep(snap * 0.7, 1.0, (b - from) / (to - from));
    return mixPose(poses[int(danceKeys[i].y)], poses[int(danceKeys[j].y)], t);
}

inline float3x3 dRotX(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }
inline float3x3 dRotY(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
// Leans +y toward +x by a.
inline float3x3 dLean(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, -s, 0), float3(s, c, 0), float3(0, 0, 1)); }

// A limb's direction in its frame, from its swing and how far it is out to its side s
// (+1 right, -1 left), in degrees.
inline float3 limbDir(float3x3 m, float2 a, float s) {
    a *= M_PI_F / 180;
    return m * float3(sin(a.x) * cos(a.y), -cos(a.x) * cos(a.y), s * sin(a.y));
}
