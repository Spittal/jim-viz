// Jenga: a hand builds a tower of blocks on a plinth, one block each time Place fires (map Audio
// In's On Beat into it), layer on layer across each other, up to `layers`. Quake shakes the
// plinth (map Kick, Drums Stem or Intensity into it): the tower sways and blocks slide out, and
// a layer that loses its middle and a side tips everything above it over. Fallen blocks tumble
// to the ground and crumble away; the hand keeps building on whatever's left. The tower starts
// built, standing on the origin. Simulated on the CPU by JengaSim (Render/JengaMesh.swift).
// @mesh jenga

// Inputs. Palette colours everything by position along it: the dark end is the ground, the
// middle the plinth and blocks, the bright end the hand and wires (map a Palette's Colours into
// it). Spectrum shakes the stage: its bass bounces the plinth and knocks blocks loose as quake
// does, its mids sway the tower, and it raises the ground round the plinth in rings, bass
// nearest (map Audio In's Spectrum, or a stem's, into it).
// @palette pal Palette
// @spectrum spec Spectrum

// Triggers. Place has the hand put its block on the tower: over the top, down, let go, and back
// for the next. A fire while it's busy waits for it.
// @trigger place Place

// Shape: scale sizes the whole geo. layers is how tall the hand builds the tower. sides is how
// round the fingers are.
// @group Shape
// @param scale 1 0 4
// @param layers 16 1 24 int
// @param sides 6 3 12 int mesh

// Build: placeTime is how many seconds a placement takes, there and back (keep it under a beat
// to place one every beat).
// @group Build
// @param placeTime 0.45 0.1 2

// Quake: quake is how hard the ground shakes, 0 still. bounce is how high the plinth jumps with
// it, sway how far the tower leans. grip is how hard the blocks hold on: a shake past it knocks
// them out, the top ones first, so kicks chip at the top. A jump in quake that lasts a second or
// so (a drop, best seen mapping Intensity or Drums Stem) shakes every layer loose. fade is how
// many seconds a fallen block takes to crumble away once it lands.
// @group Quake
// @param quake 0 0 1
// @param bounce 1 0 3
// @param sway 1 0 3
// @param grip 0.5 0 1
// @param fade 3 0 20

// Look: blockTone picks the blocks' place on the palette, toneVar how far each block strays;
// handTone and groundTone pick the hand's and the ground's. wire draws every edge; bands steps
// the shading; fog fades the distance; bgGlow is the background. explode shatters everything
// along its faces. opacity fades the whole geo, background included, into what's drawn before it.
// @group Look
// @param opacity 1 0 1
// @param blockTone 0.6 0 1
// @param toneVar 0.2 0 1
// @param handTone 0.85 0 1
// @param groundTone 0.2 0 1
// @param wire 0 0 1
// @param bands 5 1 16 int
// @param light 1.1 0 3
// @param fog 0.04 0 0.5
// @param bgGlow 0.5 0 2
// @param explode 0 0 4

// Audio: stage is how hard the spectrum shakes the stage (0: it only moves the ground). terrain
// is how high it raises the ground.
// @group Spectrum spec
// @param stage 1 0 3
// @param terrain 1 0 3

// Layout must match MeshVertex in Render/Mesh.swift.
struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
    float4 shape;        // x = part (the hand's own codes, 0 and up), y = block or ring; see Render/JengaMesh.swift
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

// @include ../lowpoly/_hand.metal

// Must match JengaLayout and JengaPart in Render/JengaMesh.swift.
constant float BLOCK_L = 0.75, BLOCK_H = 0.15, BLOCK_W = 0.25;
constant float PLINTH_TOP = -1.0, PLINTH_R = 0.85, GROUND = -1.3;
constant int SIM_HAND = 1, SIM_BODIES = 3;
constant int TERRAIN = -1, PLINTH = -2, BLOCK = -3, HAND = 0;
// The hand mesh against the blocks, and where in it (its own units) the held block's centre sits:
// under the palm, by the knuckles.
constant float HAND_SCALE = 0.85;
constant float3 HAND_GRIP = float3(0.31, 0.33, 0.02);

struct JengaOut {
    float4 position [[position]];
    float3 world;
    float3 bary;
    float faceRand [[flat]];
    float rand [[flat]];       // a block's own random
    float lift;                // how far the spectrum raised the ground here
    int part [[flat]];
};

// Off screen: a vertex not drawn.
inline JengaOut hidden(JengaOut o) {
    o.position = float4(2, 2, 2, 1);
    return o;
}

inline float3 rotateQ(float4 q, float3 v) { return v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v); }

vertex JengaOut gen_vertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant Frame& f [[buffer(1)]],
                           constant Params& p [[buffer(2)]],
                           constant Camera& cam [[buffer(3)]],
                           const device float4* sim [[buffer(4)]],
                           texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float code = v.shape.x;
    float3 plinth = sim[0].xyz;

    JengaOut o;
    // Edges the wireframe skips read as far from them.
    int hide = int(v.bary.w + 0.5);
    o.bary = v.bary.xyz + float3(hide & 1, (hide >> 1) & 1, (hide >> 2) & 1);
    o.faceRand = v.position.w;
    o.rand = 0;
    o.lift = 0;
    o.world = 0;

    float3 pos, n = v.faceNormal.xyz;
    if (code > -0.5) {
        // The hand, its palm down over the block, fingers curled round its far side.
        o.part = HAND;
        float4 h = sim[SIM_HAND];
        float yaw = sim[SIM_HAND + 1].x;
        HandPose pose;
        float grip = saturate(h.w);
        for (int i = 0; i < 5; i++) {
            pose.bend[i] = handFist[i] * (i == 0 ? mix(0.15, 0.8, grip) : mix(0.2, 0.62, grip));
            pose.stretch[i] = 1;
        }
        pose.splay = mix(0.8, 0.0, grip);
        pose.width = 1;
        HandPoint hp = handPoint(v, pose);
        // The hand's +x (out of the palm) points down, +y (its fingers) along d, +z along the block.
        float3 d = float3(cos(yaw), 0, sin(yaw));
        float3x3 m = float3x3(float3(0, -1, 0), d, float3(-sin(yaw), 0, cos(yaw)));
        pos = h.xyz + m * ((hp.pos - HAND_GRIP) * HAND_SCALE);
        n = m * hp.faceN;
    } else if (code > -1.5) {
        // The ground: heaves with the plinth near it, and the spectrum raises it in rings.
        o.part = TERRAIN;
        float r = length(v.position.xz);
        float ramp = smoothstep(PLINTH_R * 1.05, PLINTH_R * 1.6, r);
        float lift = p.terrain > 0 ? spectrum(spec, saturate(v.shape.y) * 0.85) * p.terrain * ramp : 0.0;
        float heave = plinth.y * exp(-pow(max(r - PLINTH_R, 0.0), 2.0) * 0.8);
        pos = float3(v.position.x, GROUND + lift + heave, v.position.z);
        o.lift = lift;
    } else if (code > -2.5) {
        o.part = PLINTH;
        pos = v.position.xyz + float3(0, PLINTH_TOP, 0) + plinth;
    } else {
        // A block, where JengaSim put it, crumbling face by face as it fades.
        o.part = BLOCK;
        int i = int(v.shape.y + 0.5);
        float4 b = sim[SIM_BODIES + 2 * i], q = sim[SIM_BODIES + 2 * i + 1];
        if (b.w <= 0 || v.position.w > b.w) return hidden(o);
        float3 local = v.position.xyz * float3(BLOCK_L, BLOCK_H, BLOCK_W) * (0.75 + 0.25 * b.w);
        pos = b.xyz + rotateQ(q, local);
        n = rotateQ(q, n);
        o.rand = hash11(float(i) * 0.731 + 0.17);
    }

    pos += n * p.explode * (0.3 + v.position.w) * 0.3;
    o.world = pos * p.scale;
    o.position = cam.viewProj * float4(o.world, 1);
    return o;
}

inline float3 background(texture2d<float> pal, float2 uv, float aspect, float time, constant Params& p) {
    float2 c = uv - 0.5;
    c.x *= aspect;
    float g = saturate(1 - length(c) * 1.1);
    float n = fbm3(float3(c * 2.5, time * 0.05));
    return paletteClamp(pal, 0.04 + 0.12 * (n * 0.5 + 0.5)) * p.bgGlow * (0.15 + 0.6 * g * g);
}

fragment float4 gen_fragment(JengaOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    // Flat normal from screen-space derivatives: the low-poly look.
    float3 nrm = normalize(cross(dfdy(in.world), dfdx(in.world)));
    float3 V = normalize(cam.position.xyz - in.world);
    if (dot(nrm, V) < 0) nrm = -nrm;
    float3 Ldir = normalize(float3(-0.4, 0.85, 0.35));
    float diff = max(dot(nrm, Ldir), 0.0);
    float rim = pow(1 - saturate(dot(nrm, V)), 3.0);
    float bands = max(p.bands, 1.0);
    float shade = floor(saturate((diff * 0.75 + in.faceRand * 0.12 + 0.18) * p.light) * bands) / bands;

    float3 col;
    if (in.part == BLOCK) {
        col = palette(pal, p.blockTone + (in.rand - 0.5) * p.toneVar) * (0.3 + 0.75 * shade);
    } else if (in.part == HAND) {
        col = palette(pal, p.handTone) * (0.3 + 0.75 * shade) + paletteClamp(pal, 1.0) * rim * 0.2;
    } else if (in.part == PLINTH) {
        col = palette(pal, p.groundTone + 0.12) * (0.3 + 0.6 * shade);
    } else {
        col = palette(pal, p.groundTone + saturate(in.lift) * 0.5) * (0.25 + 0.65 * shade);
    }

    // Wireframe from barycentrics.
    float e = min(min(in.bary.x, in.bary.y), in.bary.z);
    float w = 1 - smoothstep(0.0, fwidth(e) * 1.5, e);
    col = mix(col, paletteClamp(pal, 1.0) * 1.4, w * p.wire);

    // Fog toward the background colour.
    float dist = length(cam.position.xyz - in.world);
    col = mix(col, paletteClamp(pal, 0.0) * p.bgGlow * 0.35, 1 - exp(-dist * p.fog));
    return float4(col, 1);
}

// Drawn behind. Alpha 0 marks background so feedback can trail behind geometry.
fragment float4 gen_background(FXOut in [[stage_in]],
                               texture2d<float> pal [[texture(0)]],
                               constant Frame& f [[buffer(0)]],
                               constant Params& p [[buffer(1)]]) {
    return float4(background(pal, in.uv, f.resolution.x / f.resolution.y, f.time, p), 0);
}
