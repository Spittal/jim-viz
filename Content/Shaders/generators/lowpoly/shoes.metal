// Shoes: a pair of low-poly high-top sneakers, nobody in them, dancing one 32-beat routine,
// keyed step by step below: a twist that travels sideways on heels and toes, a step and
// slide, heel digs and toe taps, a turn to the side for a backwards glide and a hopping
// scissor run, then pigeon-toed swivels with kicks, criss-cross hops and a spin on tiptoe.
//
// tempo is the dance's speed: 1 is 120 BPM. Map Audio In · Sync into Sync and it follows
// the beat instead: 1 is on the beat, 2 double time, 0.5 half time. snap holds each step and
// pops to the next (0 glides between them); energy is how far each step goes from standing
// still (0 stands, past 1 overdoes it). shimmy twists both shoes side to side on the balls of
// their feet, once a beat, on top of the routine; bounce hops them on every beat. hit jumps
// with the toes thrown out (map a kick here).
// length, width and sole size the shoe; height is how tall the high top stands above the
// ankle (0 is a low top). trim is how far the sole, toe cap and laces sit along the palette
// from the canvas.
// @mesh shoes
// @clock sync Sync
// @group Shape
// @param sides 8 3 16 int mesh
// @param length 1 0 2
// @param width 1 0 3
// @param height 1 0 3
// @param sole 1 0 4
// @param trim 0.3 0 1
// @param scale 1 0 4
// @group Dance
// @param tempo 1 0 4 rate
// @param snap 0.3 0 1
// @param energy 1 0 2
// @param shimmy 0 0 1
// @param bounce 0 0 1
// @param hit 0 0 1

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Part (the sole, canvas, toe cap, tongue and laces each their own band), Along (bass at the
// heel, highs at the toe) or Random (per face).
// @group Spectrum spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Part,Along,Random

// @include _shared.metal

// The shoe's own frame: x toward the toe, y up from the floor, z out to its side.
// soleTop and ankleY must match MeshBuilder.shoes in Render/ShoesMesh.swift.
constant float soleTop = 0.1;
constant float ankleY = 0.36;
constant float heelX = -0.34;
constant float ballX = 0.27;
constant float floorY = -0.45;

// One shoe in a step. The pair faces +x, and a shoe's own side is +z for the right, -z for
// the left.
struct Foot {
    float3 at;      // moved the way the pair faces, lifted off the floor, out to its own side
                    // (standing is 0.24; negative crosses over)
    float4 turn;    // degrees: toes turned out; heel lifted, bending at the ball (negative
                    // lifts the toes, on the heel); rolled onto its outer edge; then what
                    // the toes turn about, 0 the heel … 1 the ball
};
struct Step { Foot foot[2]; };   // right, left

constant Foot standing = { {0, 0, 0.24}, {8, 0, 0, 1} };
// hit: a jump, feet apart, toes out.
constant Foot jump = { {0, 0.55, 0.55}, {40, 30, 0, 1} };

constant Step steps[27] = {
    // 0 Twist, heels to its right: on the balls of both feet.
    {{ {{0, 0, 0.24}, {-22, 12, 0, 1}}, {{0, 0, 0.24}, {22, 12, 0, 1}} }},
    // 1 Twist, toes to its right: on both heels.
    {{ {{0, 0, 0.24}, {22, -10, 0, 0}}, {{0, 0, 0.24}, {-22, -10, 0, 0}} }},
    // 2 Twist, toes to its left.
    {{ {{0, 0, 0.24}, {-22, -10, 0, 0}}, {{0, 0, 0.24}, {22, -10, 0, 0}} }},
    // 3 Twist, heels to its left.
    {{ {{0, 0, 0.24}, {22, 12, 0, 1}}, {{0, 0, 0.24}, {-22, 12, 0, 1}} }},
    // 4 Step right: the right shoe out wide on its heel, the left pushing off its toes.
    {{ {{0, 0, 0.66}, {22, -18, 0, 0}}, {{0, 0, 0.24}, {0, 28, -12, 1}} }},
    // 5 Together.
    {{ {{0, 0, 0.24}, {8, 0, 0, 1}}, {{0, 0, 0.24}, {8, 0, 0, 1}} }},
    // 6 Step left.
    {{ {{0, 0, 0.24}, {0, 28, -12, 1}}, {{0, 0, 0.66}, {22, -18, 0, 0}} }},
    // 7 Heel dig, right: out in front, toes up.
    {{ {{0.4, 0, 0.3}, {22, -38, 0, 0}}, {{0, 0, 0.24}, {8, 0, 0, 1}} }},
    // 8 Toe tap, right: behind, up on its toes.
    {{ {{-0.36, 0, 0.2}, {-8, 62, 0, 1}}, {{0, 0, 0.24}, {8, 10, 0, 1}} }},
    // 9 Air: both off the floor, toes hanging.
    {{ {{0, 0.24, 0.26}, {8, 28, 0, 1}}, {{0, 0.24, 0.26}, {8, 28, 0, 1}} }},
    // 10 Heel dig, left.
    {{ {{0, 0, 0.24}, {8, 0, 0, 1}}, {{0.4, 0, 0.3}, {22, -38, 0, 0}} }},
    // 11 Toe tap, left.
    {{ {{0, 0, 0.24}, {8, 10, 0, 1}}, {{-0.36, 0, 0.2}, {-8, 62, 0, 1}} }},
    // 12 Glide: the right flat in front, about to slide back; the left planted on its toes.
    {{ {{0.125, 0, 0.13}, {0, 0, 0, 1}}, {{-0.125, 0, 0.13}, {0, 48, 0, 1}} }},
    // 13 Glide: the right slid back past the left.
    {{ {{-0.125, 0, 0.13}, {0, 0, 0, 1}}, {{0.125, 0, 0.13}, {0, 48, 0, 1}} }},
    // 14 Glide: the heels swap, the right up on its toes, the left flat.
    {{ {{-0.125, 0, 0.13}, {0, 48, 0, 1}}, {{0.125, 0, 0.13}, {0, 0, 0, 1}} }},
    // 15 Glide: the left slid back past the right.
    {{ {{0.125, 0, 0.13}, {0, 48, 0, 1}}, {{-0.125, 0, 0.13}, {0, 0, 0, 1}} }},
    // 16 Scissor: the right landing in front on its heel, the left behind on its toes.
    {{ {{0.3, 0, 0.13}, {0, -14, 0, 0}}, {{-0.3, 0, 0.13}, {0, 52, 0, 1}} }},
    // 17 Scissor, the left in front.
    {{ {{-0.3, 0, 0.13}, {0, 52, 0, 1}}, {{0.3, 0, 0.13}, {0, -14, 0, 0}} }},
    // 18 Pigeon: toes in, heels out and just off the floor.
    {{ {{0, 0, 0.24}, {-30, 14, 0, 1}}, {{0, 0, 0.24}, {-30, 14, 0, 1}} }},
    // 19 Duck: toes out.
    {{ {{0, 0, 0.24}, {40, 0, 0, 1}}, {{0, 0, 0.24}, {40, 0, 0, 1}} }},
    // 20 Kick, right.
    {{ {{0.5, 0.3, 0.3}, {10, -32, 0, 0}}, {{0, 0, 0.24}, {30, 0, 0, 1}} }},
    // 21 Kick, left.
    {{ {{0, 0, 0.24}, {30, 0, 0, 1}}, {{0.5, 0.3, 0.3}, {10, -32, 0, 0}} }},
    // 22 Wide.
    {{ {{0, 0, 0.52}, {16, 0, 0, 1}}, {{0, 0, 0.52}, {16, 0, 0, 1}} }},
    // 23 Crossed, the right in front.
    {{ {{0.17, 0, -0.1}, {4, 0, 0, 1}}, {{-0.17, 0, -0.1}, {4, 0, 0, 1}} }},
    // 24 Crossed, the left in front.
    {{ {{-0.17, 0, -0.1}, {4, 0, 0, 1}}, {{0.17, 0, -0.1}, {4, 0, 0, 1}} }},
    // 25 Tiptoe.
    {{ {{0, 0, 0.2}, {6, 52, 0, 1}}, {{0, 0, 0.2}, {6, 52, 0, 1}} }},
    // 26 Rolled out onto both outer edges.
    {{ {{0, 0, 0.3}, {0, 0, 26, 1}}, {{0, 0, 0.3}, {0, 0, 26, 1}} }},
};

// The routine: (the beat it arrives on, the step, the pair turned to its left in degrees, the
// pair moved toward +z). The same step twice is a hold; two keys on one beat jump from the
// first to the second (a full turn back to 0). It loops after danceBeats.
constant float danceBeats = 32;
constant int danceKeyCount = 63;
constant float4 danceKeys[63] = {
    // Bar 1: the twist, travelling to its right and back.
    {0, 0, 0, 0}, {0.5, 1, 0, 0.2}, {1, 0, 0, 0.4}, {1.5, 1, 0, 0.6}, {2, 2, 0, 0.45}, {2.5, 3, 0, 0.3}, {3, 2, 0, 0.15}, {3.5, 3, 0, 0},
    // Bar 2: step right and slide together, step left and slide together.
    {4, 4, 0, 0}, {4.5, 4, 0, 0}, {5, 5, 0, 0.42}, {5.6, 5, 0, 0.42}, {6, 6, 0, 0.42}, {6.5, 6, 0, 0.42}, {7, 5, 0, 0}, {7.6, 5, 0, 0},
    // Bar 3: heel, toe, heel and a hop, on the right then the left.
    {8, 7, 0, 0}, {8.5, 8, 0, 0}, {9, 7, 0, 0}, {9.5, 9, 0, 0}, {10, 10, 0, 0}, {10.5, 11, 0, 0}, {11, 10, 0, 0}, {11.5, 9, 0, 0},
    // Bar 4: side on, gliding backwards. The shoe on its toes stays where it is on the floor.
    {12, 12, -90, 0}, {12.7, 13, -90, -0.25}, {13, 14, -90, -0.25}, {13.7, 15, -90, -0.5},
    {14, 12, -90, -0.5}, {14.7, 13, -90, -0.75}, {15, 14, -90, -0.75}, {15.7, 15, -90, -1},
    // Bar 5: a hopping scissor run back to the middle.
    {16, 16, -90, -0.75}, {16.5, 9, -90, -0.625}, {17, 17, -90, -0.5}, {17.5, 9, -90, -0.375},
    {18, 16, -90, -0.25}, {18.5, 9, -90, -0.125}, {19, 17, -90, 0}, {19.5, 9, -90, 0},
    // Bar 6: to the front. Pigeon and duck swivels, then a kick from each.
    {20, 18, 0, 0}, {20.5, 19, 0, 0}, {21, 18, 0, 0}, {21.5, 19, 0, 0}, {22, 20, 0, 0}, {22.5, 18, 0, 0}, {23, 21, 0, 0}, {23.5, 18, 0, 0},
    // Bar 7: hops, wide then crossed.
    {24, 22, 0, 0}, {24.5, 9, 0, 0}, {25, 23, 0, 0}, {25.5, 9, 0, 0}, {26, 22, 0, 0}, {26.5, 9, 0, 0}, {27, 24, 0, 0}, {27.5, 9, 0, 0},
    // Bar 8: a spin on tiptoe, a heel dig, a roll out and a hop back into the twist.
    {28, 22, 0, 0}, {28.5, 25, 0, 0}, {30, 25, -360, 0}, {30, 25, 0, 0}, {30.4, 7, 0, 0}, {31, 26, 0, 0}, {31.5, 9, 0, 0},
};

// Turns that take a point's place and a normal's direction alike, by a in radians.
// Lifts the heel: what is behind the origin rises.
inline float3 heelUp(float3 q, float a) { float c = cos(a), s = sin(a); return float3(q.x * c + q.y * s, q.y * c - q.x * s, q.z); }
// Rolls toward the shoe's outer side: what is inside the origin rises.
inline float3 rollOut(float3 q, float a) { float c = cos(a), s = sin(a); return float3(q.x, q.y * c - q.z * s, q.z * c + q.y * s); }
// Turns the toes out to the shoe's side.
inline float3 toesOut(float3 q, float a) { float c = cos(a), s = sin(a); return float3(q.x * c - q.z * s, q.y, q.x * s + q.z * c); }
// Turns the pair to its left.
inline float3 turnLeft(float3 q, float a) { float c = cos(a), s = sin(a); return float3(q.x * c + q.z * s, q.y, q.z * c - q.x * s); }

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int shoe = int(v.shape.x + 0.5), part = int(v.shape.y + 0.5);
    float side = shoe == 0 ? 1 : -1;
    float deg = M_PI_F / 180;

    // This shoe's place in the routine at this beat.
    float beat = p.tempoPhase * 2;
    float b = beat - floor(beat / danceBeats) * danceBeats;
    int i = 0;
    for (int k = 1; k < danceKeyCount; k++) { if (danceKeys[k].x <= b) i = k; }
    int j = (i + 1) % danceKeyCount;
    float from = danceKeys[i].x, to = j == 0 ? danceBeats : danceKeys[j].x;
    float t = smoothstep(p.snap * 0.7, 1.0, (b - from) / (to - from));
    Foot a = steps[int(danceKeys[i].y)].foot[shoe], c = steps[int(danceKeys[j].y)].foot[shoe];
    float3 at = mix(a.at, c.at, t);
    float4 turn = mix(a.turn, c.turn, t);
    float facing = mix(danceKeys[i].z, danceKeys[j].z, t);
    float travel = mix(danceKeys[i].w, danceKeys[j].w, t) * p.energy;

    // As far from standing as energy takes it (the pair always turns the routine's way), then
    // the shimmy, the bounce and the hit.
    at = mix(standing.at, at, p.energy);
    turn = mix(standing.turn, turn, p.energy);
    float twist = sin(beat * 2 * M_PI_F);
    turn.x += side * twist * 30 * p.shimmy;
    turn.y += (12 + 10 * side * twist) * p.shimmy;
    turn.w = mix(turn.w, 1.0, p.shimmy);
    float hop = 4 * fract(beat) * (1 - fract(beat));
    at.y += hop * 0.3 * p.bounce;
    turn.y += hop * 22 * p.bounce;
    at = mix(at, jump.at, p.hit);
    turn = mix(turn, jump.turn, p.hit);
    at.y = max(at.y, 0.0);

    // The shoe, sized: the high top stretches above the ankle, the sole thickens under the rest.
    float3 q = v.position.xyz;
    q.x *= p.length;
    q.z *= p.width;
    q.y = q.y > ankleY ? ankleY + (q.y - ankleY) * p.height : q.y;
    q.y = q.y < soleTop ? q.y * p.sole : q.y + soleTop * (p.sole - 1);
    float heel = heelX * p.length, ball = ballX * p.length;

    // Placed. A lifted heel bends the shoe at the ball, so the toes stay flat on the floor;
    // lifted toes tip the whole shoe back on its heel. It rolls about the edge it rolls onto.
    float bend = max(turn.y, 0.0) * deg * (1 - smoothstep(ball - 0.1, ball + 0.1, q.x));
    float tip = max(-turn.y, 0.0) * deg;
    float roll = turn.z * deg, out = turn.x * deg;
    float edge = (roll > 0 ? 0.17 : -0.15) * p.width;
    float pivot = mix(heel, ball, saturate(turn.w));
    float3 pos = q;
    pos = heelUp(pos - float3(ball, 0, 0), bend) + float3(ball, 0, 0);
    pos = heelUp(pos - float3(heel, 0, 0), -tip) + float3(heel, 0, 0);
    pos = rollOut(pos - float3(0, 0, edge), roll) + float3(0, 0, edge);
    pos = toesOut(pos - float3(pivot, 0, 0), out) + float3(pivot, 0, 0);
    pos += at;
    pos.z *= side;
    pos = turnLeft(pos, facing * deg) + float3(0, floorY, travel);

    float3 n = toesOut(rollOut(heelUp(heelUp(v.smoothNormal.xyz, bend), -tip), roll), out);
    float3 fn = toesOut(rollOut(heelUp(heelUp(v.faceNormal.xyz, bend), -tip), roll), out);
    n.z *= side;
    fn.z *= side;
    n = turnLeft(n, facing * deg);
    fn = turnLeft(fn, facing * deg);

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? (float(part) + 0.5) / 6 : mode == 1 ? 0.1 + 0.9 * saturate(v.position.x + 0.43) : v.position.w;
    GeoPoint g = geoPoint(pos, n, fn, u);
    // The sole, toe cap and laces are the trim; the inside of the collar is dark.
    g.tone = (part == 0 || part == 2 || part == 4) ? p.trim : 0.0;
    g.dark = part == 5 ? 0.7 : 0.0;
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
