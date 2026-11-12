// Shrek: a stocky low-poly ogre, sixteen faceted bones (pelvis, chest, head, arms with fists,
// legs, feet, two trumpet ears and a nose), each a `sides`-sided shard. He dances one 32-beat
// routine, keyed pose by pose below, slow and smooth: a hip sway with his hands on his hips
// and then behind his head, body waves, shoulder rolls, a sway with his back turned, looking
// over his shoulder, a slow dip and rise side on, and a beckon to finish. His hips roll in a
// circle all the way through.
//
// He takes his colours from the Palette like every geo: map a green one in for an ogre.
// clothes shifts his vest, trousers and boots along the palette, and clothesDark darkens them.
//
// tempo is the dance's speed: 1 is 120 BPM. Map Audio In · Sync into Sync and it follows
// the beat instead: 1 is on the beat, 2 double time, 0.5 half time. snap holds each pose and
// pops to the next (0 glides between them); energy is how far each pose goes from standing
// still (0 stands, past 1 overdoes it). hit throws every limb out into a star and jumps (map
// a kick here); jiggle wobbles the belly. limbWidth thickens every bone, limbLength stretches
// the arms and legs, belly fattens the body, headSize scales the head (and its ears and
// nose), earSize the ears alone.
// @mesh shrek
// @clock sync Sync
// @group Shape
// @param sides 6 3 12 int mesh
// @param limbWidth 1 0 3
// @param limbLength 1 0 2
// @param belly 1 0 3
// @param headSize 1 0 3
// @param earSize 1 0 4
// @param clothes 0 0 1
// @param clothesDark 0.45 0 1
// @param scale 1 0 4
// @group Dance
// @param tempo 1 0 4 rate
// @param snap 0 0 1
// @param energy 1 0 2
// @param hit 0 0 1
// @param jiggle 0 0 1

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Limb (each bone its own band, bass in the hips), Along (bass where a bone starts, highs at
// its end) or Random (per face).
// @group Spectrum spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Limb,Along,Random

// @include _shared.metal
// @include _figure.metal

// Bone lengths. Must match MeshBuilder.shrekBones in Render/ShrekMesh.swift.
constant float boneLen[16] = { 0.22, 0.4, 0.36, 0.3, 0.27, 0.3, 0.27, 0.34, 0.32, 0.24, 0.34, 0.32, 0.24, 0.17, 0.17, 0.09 };
constant float floorY = -1.0;
constant float ankleHeight = 0.08;
constant float hipWidth = 0.13;
constant float shoulderWidth = 0.3;

constant Pose standing = { {0, 0, 0}, {0, 0, 0}, {0, 0}, {0, 0}, {{0, 22, 15, 14}, {0, 22, 15, 14}}, {{2, 8, -2, 6}, {2, 8, -2, 6}} };
// hit: a star jump.
constant float4 starArm = {180, 55, 180, 58};
constant float4 starLeg = {0, 36, 0, 38};

constant Pose poses[13] = {
    // 0 Hip right: hands on his hips, the hips swung out to his right, the left knee soft.
    { {0, 0, -9}, {0, -4, 12}, {-8, 0}, {0, 0.1}, {{-20, 52, 5, -50}, {-20, 52, 5, -50}}, {{4, 4, -2, 2}, {12, 22, -14, 12}} },
    // 1 Hip left.
    { {0, 0, 9}, {0, -4, -12}, {8, 0}, {0, -0.1}, {{-20, 52, 5, -50}, {-20, 52, 5, -50}}, {{12, 22, -14, 12}, {4, 4, -2, 2}} },
    // 2 Hip right, his right hand behind his head, the chest turned and lifted.
    { {0, 0, -9}, {8, -6, 12}, {-12, -6}, {0, 0.1}, {{160, 42, -90, -70}, {-20, 52, 5, -50}}, {{4, 4, -2, 2}, {12, 22, -14, 12}} },
    // 3 Hip left, both hands behind his head.
    { {0, 0, 9}, {-6, -8, -12}, {10, -8}, {0, -0.1}, {{160, 42, -90, -70}, {160, 42, -90, -70}}, {{12, 22, -14, 12}, {4, 4, -2, 2}} },
    // 4 Reach: the top of a body wave, both arms stretched up over his head, the chest lifted.
    { {0, -4, 0}, {0, -10, 0}, {0, -12}, {0.04, 0}, {{172, 14, 186, -22}, {172, 14, 186, -22}}, {{4, 10, -2, 6}, {10, 14, -12, 6}} },
    // 5 Sink: the bottom of the wave, knees bent, his hands sliding down his thighs.
    { {0, 8, 0}, {0, 10, 0}, {0, 8}, {-0.05, 0}, {{22, 16, 40, -14}, {22, 16, 40, -14}}, {{40, 12, -24, 6}, {40, 12, -24, 6}} },
    // 6 Away: his back to the front, looking over his shoulder, a hand behind his head, hip right.
    { {-130, 0, -8}, {0, -4, 10}, {70, -4}, {0, 0}, {{-20, 52, 5, -50}, {160, 42, -90, -70}}, {{4, 4, -2, 2}, {12, 22, -14, 12}} },
    // 7 Away, hip left.
    { {-130, 0, 8}, {0, -4, -10}, {70, -4}, {0, 0}, {{-20, 52, 5, -50}, {160, 42, -90, -70}}, {{12, 22, -14, 12}, {4, 4, -2, 2}} },
    // 8 Dip: side on, sunk low, his back arched and his hands on his knees.
    { {-90, 14, 0}, {0, -12, 0}, {35, -10}, {0, 0}, {{38, 10, 22, 0}, {38, 10, 22, 0}}, {{72, 10, -34, 5}, {72, 10, -34, 5}} },
    // 9 Rise: side on, standing tall, the chest forward and both arms up.
    { {-90, -4, 0}, {0, -10, 0}, {40, -8}, {0, 0}, {{168, 12, 188, -12}, {168, 12, 188, -12}}, {{6, 6, -10, 4}, {14, 6, -14, 4}} },
    // 10 Shoulder roll right: arms low and open, the right shoulder dipped and forward.
    { {0, 0, 5}, {-14, 0, 7}, {10, -5}, {0, 0.05}, {{10, 48, 25, 62}, {15, 36, 40, 30}}, {{4, 8, -2, 4}, {10, 22, -14, 12}} },
    // 11 Shoulder roll left.
    { {0, 0, -5}, {14, 0, -7}, {-10, -5}, {0, -0.05}, {{15, 36, 40, 30}, {10, 48, 25, 62}}, {{10, 22, -14, 12}, {4, 8, -2, 4}} },
    // 12 Beckon: hip right, a hand behind his head, the other reaching out to the front.
    { {0, 0, -9}, {8, -6, 12}, {-5, 5}, {0, 0.1}, {{160, 42, -90, -70}, {70, 15, 80, 5}}, {{4, 4, -2, 2}, {12, 22, -14, 12}} },
};

constant float danceBeats = 32;
constant int danceKeyCount = 27;
constant float2 danceKeys[27] = {
    // Bar 1: a slow hip sway, hands on his hips.
    {0, 0}, {1, 1}, {2, 0}, {3, 1},
    // Bar 2: still swaying, one hand and then the other up behind his head.
    {4, 2}, {5, 3}, {6, 2}, {7, 3},
    // Bar 3: a body wave, up and slowly down.
    {8, 4}, {10, 5},
    // Bar 4: back up, then shoulder rolls.
    {12, 4}, {13, 10}, {14, 11}, {15, 10},
    // Bar 5: turned away, swaying, looking back over his shoulder.
    {16, 6}, {17, 7}, {18, 6}, {19, 7},
    // Bar 6: side on, arms up, then a slow dip.
    {20, 9}, {22, 8},
    // Bar 7: a slow rise, then round to the front into another wave.
    {24, 9}, {26, 4}, {27, 5},
    // Bar 8: the sway again, and a beckon, held.
    {28, 2}, {29, 3}, {30, 12}, {31, 12},
};

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
    // routine's way), then the hit.
    float beat = p.tempoPhase * 2;
    Pose ps = danceAt(poses, danceKeys, danceKeyCount, danceBeats, beat, p.snap);
    // Under every pose his hips roll in a slow circle, once round every two beats, so he
    // never quite stops between them.
    ps.shift += float2(sin(beat * M_PI_F), cos(beat * M_PI_F)) * 0.04;
    float turn = ps.body.x;
    ps = mixPose(standing, ps, p.energy);
    ps.body.x = turn;
    for (int i = 0; i < 2; i++) {
        ps.arm[i] = mix(ps.arm[i], starArm, p.hit);
        ps.leg[i] = mix(ps.leg[i], starLeg, p.hit);
    }

    // Frames: Y turns with the body, R is the hips, T the chest, H the head, A what the arms
    // are set against.
    float3x3 Y = dRotY(ps.body.x * deg);
    float3x3 R = Y * dLean(ps.body.y * deg) * dRotX(ps.body.z * deg);
    float3x3 T = R * dRotY(ps.spine.x * deg) * dLean(ps.spine.y * deg) * dRotX(ps.spine.z * deg);
    float3x3 H = T * dRotY(ps.head.x * deg) * dLean(ps.head.y * deg);
    float3x3 A = dRotY((ps.body.x + ps.spine.x) * deg);

    // Both legs, from the hips (the origin for now), to find the floor.
    float3 hip[2], knee[2], ankle[2], thighDir[2], shinDir[2];
    for (int i = 0; i < 2; i++) {
        float s = i == 0 ? 1 : -1;
        hip[i] = R * float3(0, 0, s * hipWidth);
        thighDir[i] = limbDir(Y, ps.leg[i].xy, s);
        shinDir[i] = limbDir(Y, ps.leg[i].zw, s);
        knee[i] = hip[i] + thighDir[i] * boneLen[7] * p.limbLength;
        ankle[i] = knee[i] + shinDir[i] * boneLen[8] * p.limbLength;
    }
    float lowest = min(ankle[0].y, ankle[1].y);
    float3 root = float3(ps.shift.x, floorY + ankleHeight - lowest + p.hit * 0.3, ps.shift.y);
    float3 waist = root + R[1] * boneLen[0];
    float3 neck = waist + T[1] * boneLen[1] * 0.92;
    float headWidth = p.limbWidth * p.headSize;

    // Where this bone starts, the way it runs, which way is sideways on it, and how long and
    // wide it is drawn.
    float len = boneLen[bone] * (bone >= 13 ? p.headSize : bone >= 3 ? p.limbLength : bone == 2 ? p.headSize : 1.0);
    float width = p.limbWidth;
    float3 start, dir, side;
    if (bone == 0) {
        start = root;
        dir = R[1];
        side = R[2];
        width *= p.belly;
    } else if (bone == 1) {
        start = waist;
        dir = T[1];
        side = T[2];
        width *= p.belly;
    } else if (bone == 2) {
        start = neck;
        dir = H[1];
        side = H[2];
        width = headWidth;
    } else if (bone < 7) {
        int i = (bone - 3) / 2;
        float s = i == 0 ? 1 : -1;
        start = waist + T * float3(0, boneLen[1] * 0.85, s * shoulderWidth);
        dir = limbDir(A, ps.arm[i].xy, s);
        if (bone % 2 == 0) {
            start += dir * boneLen[3] * p.limbLength;
            dir = limbDir(A, ps.arm[i].zw, s);
        }
        // Somewhere an arm rarely points, so the fist doesn't flip over.
        side = A * float3(-0.62, -0.31, -0.72 * s);
    } else if (bone < 13) {
        int i = (bone - 7) / 3, k = (bone - 7) % 3;
        float s = i == 0 ? 1 : -1;
        start = root + (k == 0 ? hip[i] : k == 1 ? knee[i] : ankle[i]);
        dir = k == 0 ? thighDir[i] : shinDir[i];
        if (k == 2) {
            // A foot on the floor lies flat, toes turned out with its leg; lifted, it hangs from the shin.
            float out = max(ps.leg[i].y, 0.0) * 0.6 * deg;
            float3 flat = Y * float3(cos(out), -0.25, s * sin(out));
            float lift = saturate((ankle[i].y - lowest) / 0.3);
            dir = normalize(mix(flat, shinDir[i] + flat * 0.5, lift));
        }
        side = Y[2];
    } else if (bone < 15) {
        // An ear, sticking out of the side of the head and a little up.
        float s = bone == 13 ? 1 : -1;
        start = neck + H[1] * boneLen[2] * p.headSize * 0.72 + H[2] * s * 0.14 * headWidth;
        dir = normalize(H * float3(0, 0.45, s));
        side = H[0];
        len *= p.earSize;
        width = headWidth * p.earSize;
    } else {
        // The nose, out of the front of the face.
        start = neck + H[1] * boneLen[2] * p.headSize * 0.5 + H[0] * 0.15 * headWidth;
        dir = H[0];
        side = H[2];
        width = headWidth;
    }
    float3 S1 = side - dot(side, dir) * dir;
    S1 = length(S1) > 1e-3 ? normalize(S1) : normalize(cross(dir, float3(0.3, 1, 0.2)));
    float3 S2 = cross(dir, S1);

    // jiggle: the belly wobbles, rolling up the body.
    if (bone < 2) width *= 1 + p.jiggle * 0.3 * noise3(float3(f.time * 5, (float(bone) + v.shape.y) * 2.5, 3));

    float3 off = (v.shape.z * S1 + v.shape.w * S2) * width;
    float3 pos = start + dir * v.shape.y * len + off;
    float3 n = length(off) > 1e-5 ? normalize(off) : dir * sign(v.shape.y - 0.5);
    float3 lf = v.faceNormal.xyz;
    float3 fn = lf.x * dir + lf.y * S1 + lf.z * S2;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? (float(bone) + 0.5) / 16 : mode == 1 ? 0.2 + saturate(v.shape.y) * 0.8 : v.position.w;
    GeoPoint g = geoPoint(pos, n, fn, u);
    // His vest, trousers and boots; his head, arms and fists are bare.
    if (bone < 2 || (bone >= 7 && bone < 13)) {
        g.tone = p.clothes;
        g.dark = p.clothesDark;
    }
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
