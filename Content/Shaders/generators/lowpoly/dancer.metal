// Dancer: a lean, faceless low-poly figure, thirteen faceted bones (pelvis, chest, head, arms,
// legs, feet), each a `sides`-sided shard. It dances one 32-beat routine, keyed pose by pose
// below: a hands-up groove, a knee lift, squats and diagonal disco points facing the front,
// then a turn to the side for a creep, a hands-to-head bounce, a lean back, and a lunge with
// both arms thrust out, pulsing, before it turns back to the front.
//
// tempo is the dance's speed: 1 is 120 BPM. Map Clock · Sync into Sync and it follows the
// Clock instead: 1 is on the beat, 2 double time, 0.5 half time. snap holds each pose and
// pops to the next (0 glides between them); energy is how far each pose goes from standing
// still (0 stands, past 1 overdoes it). hit throws every limb out into a star and jumps (map
// a kick here); flail jerks the limbs about on their own. limbWidth thickens every bone,
// limbLength stretches the arms and legs, headSize scales the head.
// @mesh dancer
// @clock sync Sync
// @group Shape
// @param sides 5 3 12 int mesh
// @param limbWidth 1 0 3
// @param limbLength 1 0 2
// @param headSize 1 0 3
// @group Dance
// @param tempo 1 0 4 rate
// @param snap 0.3 0 1
// @param energy 1 0 2
// @param hit 0 0 1
// @param flail 0 0 1

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Limb (each bone its own band, bass in the hips), Along (bass where a bone starts, highs at
// its end) or Random (per face).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Limb,Along,Random

// @include _shared.metal

// Bone lengths. Must match MeshBuilder.dancerBones in Render/DancerMesh.swift.
constant float boneLen[13] = { 0.2, 0.42, 0.34, 0.33, 0.29, 0.33, 0.29, 0.48, 0.46, 0.2, 0.48, 0.46, 0.2 };
constant float floorY = -1.0;
constant float ankleHeight = 0.07;

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

constant Pose standing = { {0, 0, 0}, {0, 0, 0}, {0, 0}, {0, 0}, {{0, 8, 15, 6}, {0, 8, 15, 6}}, {{2, 4, -2, 3}, {2, 4, -2, 3}} };
// hit: a star jump.
constant float4 starArm = {180, 52, 180, 56};
constant float4 starLeg = {0, 34, 0, 36};

constant Pose poses[22] = {
    // 0 Groove right: fists up by its right shoulder.
    { {-15, 0, 4}, {-10, 0, 3}, {10, 0}, {0, 0.03}, {{10, 22, 168, 18}, {45, -10, 120, -60}}, {{5, 4, -12, 3}, {12, 3, -8, 3}} },
    // 1 Groove centre: fists at the chest, a dip.
    { {0, 0, 0}, {0, 4, 0}, {0, 0}, {0, 0}, {{15, 18, 125, -30}, {15, 18, 125, -30}}, {{14, 4, -14, 3}, {14, 4, -14, 3}} },
    // 2 Groove left.
    { {15, 0, -4}, {10, 0, -3}, {-10, 0}, {0, -0.03}, {{45, -10, 120, -60}, {10, 22, 168, 18}}, {{12, 3, -8, 3}, {5, 4, -12, 3}} },
    // 3 Knee: right knee up, right arm flung out.
    { {0, 0, -6}, {-8, 0, -4}, {-15, 0}, {0, -0.05}, {{5, 80, 10, 86}, {10, 20, 115, -35}}, {{95, 12, -15, 5}, {0, 2, -3, 2}} },
    // 4 Knee held, the hand back at the chest.
    { {0, 0, -4}, {0, 0, -2}, {0, 0}, {0, -0.05}, {{15, 25, 120, -30}, {10, 20, 115, -35}}, {{85, 10, -10, 5}, {0, 2, -3, 2}} },
    // 5 Squat: feet wide, knees out, arms low and wide.
    { {0, 6, 0}, {0, 8, 0}, {0, 5}, {0, 0}, {{5, 38, 25, 48}, {5, 38, 25, 48}}, {{38, 38, -18, 14}, {38, 38, -18, 14}} },
    // 6 Point: one line from the feet up through the right hand, the left arm out low.
    { {0, 0, 10}, {0, -3, 6}, {-10, -8}, {0, 0.05}, {{180, 48, 180, 50}, {0, 62, 0, 72}}, {{0, 3, 0, 3}, {8, -6, -30, -2}} },
    // 7 Over: the right arm curled over the head.
    { {0, 0, 3}, {0, 0, 2}, {0, 0}, {0, 0}, {{175, 25, 170, -65}, {5, 35, 15, 50}}, {{8, 20, -6, 10}, {8, 20, -6, 10}} },
    // 8 Sweep: a lunge to its right, both arms thrown out to its left.
    { {15, 5, 12}, {20, 5, 5}, {-20, 0}, {0, 0.22}, {{85, -40, 88, -70}, {30, 78, 50, 82}}, {{45, 42, -20, 8}, {0, 42, 0, 44}} },
    // 9 Arms up.
    { {0, 0, 0}, {0, -4, 0}, {0, -8}, {0, 0}, {{150, 35, 178, 5}, {150, 35, 178, 5}}, {{5, 22, -5, 10}, {5, 22, -5, 10}} },
    // 10 Face: turning to the side, hands to the face.
    { {-50, 0, 0}, {-10, 0, 0}, {0, 0}, {0, 0}, {{60, 20, 150, -25}, {60, 20, 150, -25}}, {{6, 5, -8, 3}, {6, 5, -8, 3}} },
    // 11 Creep: side on, crouched, hands out in front.
    { {-90, 8, 0}, {0, 10, 0}, {0, -5}, {0, 0}, {{35, 10, 105, -5}, {35, 10, 105, -5}}, {{30, 5, -34, 3}, {36, 5, -28, 3}} },
    // 12 Creep low: a step, reaching down.
    { {-90, 15, 0}, {0, 15, 0}, {0, 10}, {0, 0.1}, {{45, 10, 65, 0}, {45, 10, 65, 0}}, {{15, 5, -75, 3}, {78, 5, -12, 3}} },
    // 13 Head, up: standing tall, hands by the head.
    { {-90, -4, 0}, {0, 0, 0}, {0, -5}, {0, 0}, {{80, 25, 195, -15}, {80, 25, 195, -15}}, {{12, 4, -12, 3}, {12, 4, -12, 3}} },
    // 14 Head, down: the same, squatting.
    { {-90, 8, 0}, {0, 10, 0}, {0, 0}, {0, 0}, {{85, 25, 190, -15}, {85, 25, 190, -15}}, {{60, 8, -42, 4}, {60, 8, -42, 4}} },
    // 15 Reach: a long step, hands low in front.
    { {-90, 20, 0}, {0, 20, 0}, {0, -10}, {0, 0.15}, {{40, 10, 60, 5}, {40, 10, 60, 5}}, {{-8, 5, -72, 0}, {70, 5, -22, 0}} },
    // 16 Arms forward: stepping back, both arms straight out.
    { {-90, -8, 0}, {0, 0, 0}, {0, 0}, {0, -0.2}, {{95, 6, 92, 0}, {95, 6, 92, 0}}, {{30, 5, -30, 3}, {30, 5, -30, 3}} },
    // 17 Lean back: arms thrown over the head, a leg kicked up behind.
    { {-90, -18, 0}, {0, -8, 0}, {0, -10}, {0, -0.45}, {{165, 12, 205, 5}, {165, 12, 205, 5}}, {{28, 5, -22, 3}, {-5, 5, -100, 0}} },
    // 18 Wind up: a lunge, elbows pulled back.
    { {-90, 12, 0}, {0, 10, 0}, {0, -5}, {0, 0.1}, {{-45, 12, 35, 5}, {-45, 12, 35, 5}}, {{-38, 5, -58, 0}, {72, 5, -8, 0}} },
    // 19 Thrust, high: a long lunge, one line from the back foot to the head, both arms thrust out.
    { {-90, 28, 0}, {0, 8, 0}, {0, -25}, {0, 0.3}, {{93, 6, 92, -2}, {93, 6, 92, -2}}, {{-44, 5, -44, 0}, {58, 5, -12, 0}} },
    // 20 Thrust, low: sunk into the lunge.
    { {-90, 10, 0}, {0, 5, 0}, {0, -10}, {0, 0.25}, {{92, 6, 92, -2}, {92, 6, 92, -2}}, {{-28, 5, -82, 0}, {86, 5, -4, 0}} },
    // 21 Rise: standing side on, fists at the chest.
    { {-90, 0, 0}, {0, 0, 0}, {0, 0}, {0, 0}, {{20, 15, 120, -25}, {20, 15, 120, -25}}, {{10, 4, -10, 3}, {10, 4, -10, 3}} },
};

// The routine: (the beat it arrives on, the pose). The same pose twice is a hold. It loops
// after danceBeats.
constant float danceBeats = 32;
constant int danceKeyCount = 65;
constant float2 danceKeys[65] = {
    // Bar 1: groove.
    {0, 0}, {0.5, 1}, {1, 2}, {1.5, 1}, {2, 0}, {2.5, 1}, {3, 2}, {3.5, 1},
    // Bar 2: knee, squat, point, squat.
    {4, 3}, {4.6, 4}, {5, 5}, {5.6, 5}, {6, 6}, {6.6, 6}, {7, 5}, {7.6, 7},
    // Bar 3: point, squat, sweep, point, squat, sweep.
    {8, 6}, {8.5, 6}, {9, 5}, {9.4, 8}, {9.75, 7}, {10, 6}, {10.5, 6}, {11, 5}, {11.5, 8},
    // Bar 4: arms up, turn to the side, creep.
    {12, 9}, {12.5, 10}, {13, 11}, {13.5, 12}, {14, 11}, {14.5, 12}, {15, 11}, {15.5, 11},
    // Bar 5: hands to the head, up and down.
    {16, 13}, {16.5, 13}, {17, 14}, {17.5, 14}, {18, 13}, {18.5, 13}, {19, 14}, {19.5, 14},
    // Bar 6: up, reach, arms forward, lean back.
    {20, 13}, {20.5, 13}, {21, 15}, {21.6, 15}, {22, 16}, {22.6, 16}, {23, 17}, {23.6, 17},
    // Bar 7: arms forward, wind up, thrust.
    {24, 16}, {24.5, 11}, {25, 18}, {25.6, 18}, {26, 19}, {26.6, 19}, {27, 20}, {27.6, 20},
    // Bar 8: thrust high, low, high, rise and turn back to the front.
    {28, 19}, {28.6, 19}, {29, 20}, {29.6, 20}, {30, 19}, {30.6, 19}, {31, 21}, {31.4, 21},
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

// The routine's pose at a beat. snap holds each pose, then pops to the next.
inline Pose danceAt(float beat, float snap) {
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

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int bone = int(v.shape.x + 0.5);
    float deg = M_PI_F / 180;

    // The pose: the routine, as far from standing as energy takes it (but always turned the
    // routine's way), then the hit and the flail.
    Pose ps = danceAt(p.tempoPhase * 2, p.snap);
    float turn = ps.body.x;
    ps = mixPose(standing, ps, p.energy);
    ps.body.x = turn;
    for (int i = 0; i < 2; i++) {
        ps.arm[i] = mix(ps.arm[i], starArm, p.hit);
        ps.leg[i] = mix(ps.leg[i], starLeg, p.hit);
        if (p.flail > 0) {
            float t = f.time * 3, k = float(i) * 9;
            ps.arm[i] += float4(noise3(float3(t, k, 1)), noise3(float3(t, k, 2)), noise3(float3(t, k, 3)), noise3(float3(t, k, 4))) * p.flail * 90;
            ps.leg[i] += float4(noise3(float3(t, k, 5)), noise3(float3(t, k, 6)), noise3(float3(t, k, 7)), noise3(float3(t, k, 8))) * p.flail * 45;
        }
    }

    // Frames: Y turns with the body, R is the hips, T the chest, A what the arms are set against.
    float3x3 Y = dRotY(ps.body.x * deg);
    float3x3 R = Y * dLean(ps.body.y * deg) * dRotX(ps.body.z * deg);
    float3x3 T = R * dRotY(ps.spine.x * deg) * dLean(ps.spine.y * deg) * dRotX(ps.spine.z * deg);
    float3x3 A = dRotY((ps.body.x + ps.spine.x) * deg);

    // Both legs, from the hips (the origin for now), to find the floor.
    float3 hip[2], knee[2], ankle[2], thighDir[2], shinDir[2];
    for (int i = 0; i < 2; i++) {
        float s = i == 0 ? 1 : -1;
        hip[i] = R * float3(0, 0, s * 0.09);
        thighDir[i] = limbDir(Y, ps.leg[i].xy, s);
        shinDir[i] = limbDir(Y, ps.leg[i].zw, s);
        knee[i] = hip[i] + thighDir[i] * boneLen[7] * p.limbLength;
        ankle[i] = knee[i] + shinDir[i] * boneLen[8] * p.limbLength;
    }
    float lowest = min(ankle[0].y, ankle[1].y);
    float3 root = float3(ps.shift.x, floorY + ankleHeight - lowest + p.hit * 0.3, ps.shift.y);
    float3 waist = root + R[1] * boneLen[0];

    // Where this bone starts, the way it runs, and which way is sideways on it.
    float len = boneLen[bone] * (bone >= 3 ? p.limbLength : bone == 2 ? p.headSize : 1.0);
    float3 start, dir, side;
    if (bone == 0) {
        start = root;
        dir = R[1];
        side = R[2];
    } else if (bone == 1) {
        start = waist;
        dir = T[1];
        side = T[2];
    } else if (bone == 2) {
        float3x3 H = T * dRotY(ps.head.x * deg) * dLean(ps.head.y * deg);
        start = waist + T[1] * boneLen[1] * 0.98;
        dir = H[1];
        side = H[2];
    } else if (bone < 7) {
        int i = (bone - 3) / 2;
        float s = i == 0 ? 1 : -1;
        start = waist + T * float3(0, boneLen[1] * 0.9, s * 0.225);
        dir = limbDir(A, ps.arm[i].xy, s);
        if (bone % 2 == 0) {
            start += dir * boneLen[3] * p.limbLength;
            dir = limbDir(A, ps.arm[i].zw, s);
        }
        // Somewhere an arm rarely points, so the hand doesn't flip over.
        side = A * float3(-0.62, -0.31, -0.72 * s);
    } else {
        int i = (bone - 7) / 3, k = (bone - 7) % 3;
        float s = i == 0 ? 1 : -1;
        start = root + (k == 0 ? hip[i] : k == 1 ? knee[i] : ankle[i]);
        dir = k == 0 ? thighDir[i] : shinDir[i];
        if (k == 2) {
            // A foot on the floor lies flat, toes turned out with its leg; lifted, it hangs from the shin.
            float out = max(ps.leg[i].y, 0.0) * 0.6 * deg;
            float3 flat = Y * float3(cos(out), -0.3, s * sin(out));
            float lift = saturate((ankle[i].y - lowest) / 0.3);
            dir = normalize(mix(flat, shinDir[i] + flat * 0.5, lift));
        }
        side = Y[2];
    }
    float3 S1 = side - dot(side, dir) * dir;
    S1 = length(S1) > 1e-3 ? normalize(S1) : normalize(cross(dir, float3(0.3, 1, 0.2)));
    float3 S2 = cross(dir, S1);

    float width = p.limbWidth * (bone == 2 ? p.headSize : 1.0);
    float3 off = (v.shape.z * S1 + v.shape.w * S2) * width;
    float3 pos = start + dir * v.shape.y * len + off;
    float3 n = length(off) > 1e-5 ? normalize(off) : dir * sign(v.shape.y - 0.5);
    float3 lf = v.faceNormal.xyz;
    float3 fn = lf.x * dir + lf.y * S1 + lf.z * S2;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? (float(bone) + 0.5) / 13 : mode == 1 ? 0.2 + saturate(v.shape.y) * 0.8 : v.position.w;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
