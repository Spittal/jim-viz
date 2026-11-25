// City: a little Manhattan to look down on, a tile of blocks `width` across and `length` deep.
// Avenues run along x and streets along z, roads ring the tile, and a river runs down its -z
// side. Buildings step back as they climb and carry water towers; some blocks are parks. Cars
// drive the avenues and streets and stop at red lights, and people walk round the blocks and
// cross at the corners when the light lets them. It sits on the origin, ground at y 0, made
// for a camera above it (an Orbit camera high up, or Static looking straight down).
// @mesh city

// Inputs. Palette colours everything by position along it: the dark end is the roads, water and
// glass, the middle the walls, roofs and parks, the bright end the lit windows, lamps, lights
// and markings (map a Palette's Colours into it). Spectrum raises the buildings (map Audio In's
// Spectrum into it).
// @palette pal Palette
// @spectrum spec Spectrum

// Triggers. Lights Change swaps the traffic lights straight away; Reshuffle rebuilds every block
// (new heights, setbacks, rooftops and parks), as a new seed would.
// @trigger lights Lights Change
// @trigger reshuffle Reshuffle

// Shape: scale sizes the whole city (at 1, 50 metres to a unit). width and length are how many
// blocks across (z) and deep (x). blockLength is a block's length along the avenues and
// blockWidth between them, in metres; avenue, street and sidewalk are their widths. river is
// the water's width down the -z side (0: none). figures sizes the cars, people, lamps, lights and
// trees against the city, so they still read from high up.
// @group Shape
// @param scale 1 0 4
// @param width 4 1 16 int
// @param length 8 1 16 int
// @param blockLength 40 10 120
// @param blockWidth 90 10 240
// @param avenue 16 4 40
// @param street 10 4 30
// @param sidewalk 3 0.5 8
// @param river 50 0 200
// @param figures 1 0 6

// Buildings: detail adds setbacks, water towers and plant rooms (1), then ledges and spires (2).
// seed reshuffles the blocks. height is a typical building's in metres, heightVar how far they
// stray; towers is the share that are skyscrapers; skyline gathers the tall ones in the middle.
// setbacks is how much the tall ones step back as they climb; gap opens alleys between them.
// parks is the share of blocks that are parks.
// @group Buildings
// @param detail 1 0 2 int mesh
// @param seed 0 0 99 int
// @param height 35 0 150
// @param heightVar 0.6 0 1
// @param towers 0.15 0 1
// @param skyline 0.5 0 1
// @param setbacks 0.6 0 1
// @param gap 0.15 0 0.8
// @param parks 0.12 0 1

// Windows: windows is the share lit; floorHeight spaces the floors (and the windows with them);
// windowSize opens them up. flicker switches lights on and off. windowColor picks the lit
// windows', lamps' and headlights' place on the palette; glow is how bright they shine.
// @group Windows
// @param windows 0.4 0 1
// @param floorHeight 3.5 1 10
// @param windowSize 0.6 0 1
// @param flicker 0 0 4 rate
// @param windowColor 1 0 1
// @param glow 1 0 3

// Traffic: traffic is how many of the cars are out, carSpeed how fast they go (1 is 50 km/h).
// taxis is the share painted at taxiColor; the rest take colours from around carColor.
// @group Traffic
// @param traffic 0.5 0 1
// @param carSpeed 1 0 3
// @param taxis 0.3 0 1
// @param taxiColor 0.85 0 1
// @param carColor 0.5 0 1

// People: crowd is how many are out, walk how fast they go (1 is walking pace), crossing the
// share of corners where they cross to the next block rather than turn.
// @group People
// @param crowd 0.5 0 1
// @param walk 1 0 4
// @param crossing 0.5 0 1

// Lights: cycle is how many seconds the traffic lights hold before they change (0: only on
// Lights Change). goColor and stopColor are their places on the palette. lamps is the share of
// street lamps lit; each lights a pool on the ground round it.
// @group Lights
// @param cycle 10 0 60
// @param goColor 0.7 0 1
// @param stopColor 1 0 1
// @param lamps 0.6 0 1

// Look: wallTone picks the walls' place on the palette, toneVar how far each building strays
// from it; parkColor and waterColor pick the parks' and the river's. waves moves the water.
// wire draws every edge; bands steps the shading; fog fades the distance; bgGlow is the
// background. explode shatters the city along its faces. opacity fades the whole geo,
// background included, into what's drawn before it.
// @group Look
// @param opacity 1 0 1
// @param wallTone 0.45 0 1
// @param toneVar 0.3 0 1
// @param parkColor 0.35 0 1
// @param waterColor 0.15 0 1
// @param waves 0.3 0 3 rate
// @param wire 0 0 1
// @param bands 5 1 16 int
// @param light 1.1 0 3
// @param fog 0.02 0 0.5
// @param bgGlow 0.5 0 2
// @param explode 0 0 4

// Audio: eq is how far the spectrum raises the buildings. eqMode lays it out in Rings (bass in
// the middle), Across (bass on the -z side) or Random (each building its own band).
// @group Spectrum spec
// @param eq 0 0 3
// @param eqMode 0 0 2 int Rings,Across,Random

// Layout must match MeshVertex in Render/Mesh.swift.
struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
    float4 shape;        // x = extra, y = group, z = slot, w = part; see Render/CityMesh.swift
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

// Parts, groups and slots, matching CityPart, CityGroup and CitySlots in Render/CityMesh.swift.
constant int LAND = 0, WATER = 1, BASE = 2, SIDEWALK = 3, CURB = 4, WALL = 5, ROOF = 6, LEDGE = 7,
             TANK = 8, HVAC = 9, SPIRE = 10, TRUNK = 11, CROWN = 12, POST = 13, LAMP = 14,
             SIGNAL = 15, CAR = 16, CABIN = 17, SKIN = 18, CLOTHES = 19, LEGS = 20, PIER = 21;
constant int G_GROUND = 0, G_SLAB = 1, G_BUILDING = 2, G_TREE = 3, G_LAMP = 4, G_SIGNAL = 5,
             G_CAR = 6, G_PERSON = 7, G_PIER = 8;
constant int CARS_PER_BLOCK = 8, PEOPLE_PER_BLOCK = 16, MAX_SIDE = 16;
// CitySim's buffer: the lights, then the cars, then the people.
constant int SIM_CARS = 1, SIM_PEOPLE = 1 + MAX_SIDE * MAX_SIDE * CARS_PER_BLOCK;

constant float UNIT = 0.02;          // units a metre at scale 1
constant float CURB_H = 0.15;        // the sidewalks' and blocks' height
constant float WATER_Y = -1.2;       // the river's surface
constant float BASE_Y = -6;          // the bottom of the base the city stands on

struct CityOut {
    float4 position [[position]];
    float3 world;              // scaled, for the camera
    float3 m;                  // metres
    float3 bary;
    float3 local;              // the part's own coordinates: metres from a car's, person's or
                               // signal's foot; a building's box 0...1
    float faceRand [[flat]];
    float rand [[flat]];       // the building's, car's, person's or tree's own random
    float tone [[flat]];       // a building's wall colour
    float state [[flat]];      // a park block's slab 1; avenues' green for a signal; a car braking 1
    int part [[flat]];
};

inline float posMod(float x, float m) { return x - floor(x / m) * m; }

// The tile's plan in metres. Must match CityLayout in Render/CityMesh.swift.
struct Layout {
    int rows, cols;
    float bx, bz, sw, aw, side;
    float pitchX, pitchZ, sizeX, sizeZ;
    float river, landZ0, waterZ0;      // the land runs from landZ0 to sizeZ / 2, the river below it
    float cw;                          // the crosswalks' depth
};

inline Layout makeLayout(constant Params& p) {
    Layout L;
    L.rows = clamp(int(round(p.length)), 1, MAX_SIDE);
    L.cols = clamp(int(round(p.width)), 1, MAX_SIDE);
    L.bx = max(p.blockLength, 1.0);
    L.bz = max(p.blockWidth, 1.0);
    L.sw = max(p.street, 1.0);
    L.aw = max(p.avenue, 1.0);
    L.side = clamp(p.sidewalk, 0.5, min(L.bx, L.bz) * 0.3);
    L.pitchX = L.bx + L.sw;
    L.pitchZ = L.bz + L.aw;
    L.sizeX = L.rows * L.pitchX + L.sw;
    L.sizeZ = L.cols * L.pitchZ + L.aw;
    L.river = max(p.river, 0.0);
    L.landZ0 = -L.sizeZ / 2 - (L.river > 0.01 ? 2 * L.side : 0);
    L.waterZ0 = L.landZ0 - L.river;
    L.cw = max(3.0, L.side);
    return L;
}

inline float2 blockMin(Layout L, int i, int j) {
    return float2(-L.sizeX / 2 + L.sw + i * L.pitchX, -L.sizeZ / 2 + L.aw + j * L.pitchZ);
}

inline int lanesFor(float width) { return clamp(int(width / 2 / 3.2), 1, 6); }

inline float seedOf(constant Params& p) { return round(p.seed) + p.reshuffleCount * 37.0; }

inline float cityHash(int i, int j, int k, float salt, float seed) {
    return hash31(float3(i * 1.317 + k * 7.17 + 0.37, j * 2.071 + salt * 3.71, seed * 11.31 + salt * 0.913 + k * 0.29));
}

inline bool parkAt(int i, int j, constant Params& p) { return cityHash(i, j, 0, 1, seedOf(p)) < p.parks; }

// Lamp k of block (i, j): 3 along each long side (facing the streets), 1 on each short side.
inline float2 lampPos(Layout L, int i, int j, int k) {
    float2 b = blockMin(L, i, j);
    float in = 0.6;
    if (k < 3) return float2(b.x + in, b.y + L.bz * (k * 2 + 1) / 6.0);
    if (k < 6) return float2(b.x + L.bx - in, b.y + L.bz * ((k - 3) * 2 + 1) / 6.0);
    return float2(b.x + L.bx * 0.5, k == 6 ? b.y + in : b.y + L.bz - in);
}

inline bool lampOn(int i, int j, int k, constant Params& p) { return cityHash(i, j, k, 5, round(p.seed)) < p.lamps; }

// The light the lamps throw on the ground at m: the four blocks nearest.
inline float lampPools(float2 m, Layout L, constant Params& p) {
    int i0 = int(floor((m.x + L.sizeX / 2 - L.sw - L.bx * 0.5) / L.pitchX));
    int j0 = int(floor((m.y + L.sizeZ / 2 - L.aw - L.bz * 0.5) / L.pitchZ));
    float r = 7 * max(p.figures, 0.3);
    float acc = 0;
    for (int di = 0; di < 2; di++) {
        for (int dj = 0; dj < 2; dj++) {
            int i = i0 + di, j = j0 + dj;
            if (i < 0 || j < 0 || i >= L.rows || j >= L.cols) continue;
            for (int k = 0; k < 8; k++) {
                if (!lampOn(i, j, k, p)) continue;
                float2 d = m - lampPos(L, i, j, k);
                acc += exp(-dot(d, d) / (r * r));
            }
        }
    }
    return min(acc, 1.2);
}

// One lot's building. Lots are 2 deep (x) by 4 across (z) inside the sidewalk; the outer sides
// stand on the street, alleys open between them.
struct Lot {
    float2 lo, hi;          // footprint
    float H;                // height above the slab
    int tiers;
    float3 h;               // each tier's top
    float step;             // how far each tier steps back
    float rand, tone;
    bool empty;
};

inline float lotEdge(float lo, float hi, int m, int n, int i, int j, float salt, float seed) {
    if (m <= 0) return lo;
    if (m >= n) return hi;
    return mix(lo, hi, (m + (cityHash(i, j, m, salt, seed) - 0.5) * 0.45) / n);
}

inline Lot makeLot(Layout L, int i, int j, int k, constant Params& p, texture2d<float> spec) {
    float seed = seedOf(p);
    float2 b = blockMin(L, i, j);
    float2 inLo = b + L.side, inHi = b + float2(L.bx, L.bz) - L.side;
    int rx = k / 4, cz = k % 4;
    Lot o;
    o.lo = float2(lotEdge(inLo.x, inHi.x, rx, 2, i, j, 20, seed), lotEdge(inLo.y, inHi.y, cz, 4, i, j, 21, seed));
    o.hi = float2(lotEdge(inLo.x, inHi.x, rx + 1, 2, i, j, 20, seed), lotEdge(inLo.y, inHi.y, cz + 1, 4, i, j, 21, seed));
    float2 size = o.hi - o.lo;
    float2 g = p.gap * 0.5 * size * float2(cityHash(i, j, k, 22, seed), cityHash(i, j, k, 23, seed));
    if (rx == 0) o.hi.x -= g.x; else o.lo.x += g.x;
    if (cz > 0) o.lo.y += g.y;
    if (cz < 3) o.hi.y -= g.y;

    float r1 = cityHash(i, j, k, 24, seed), r2 = cityHash(i, j, k, 25, seed), r3 = cityHash(i, j, k, 26, seed);
    float H = p.height * mix(1.0, 0.3 + 1.4 * r1, p.heightVar);
    if (r2 < p.towers) H *= 2.2 + 2.0 * r3;
    float2 c = (o.lo + o.hi) * 0.5;
    float mid = 1 - saturate(length(c / (0.5 * float2(L.sizeX, L.sizeZ))));
    H *= mix(1.0, 0.35 + 1.6 * mid * mid, p.skyline);
    if (p.eq > 0) {
        int mode = int(p.eqMode + 0.5);
        float u = mode == 0 ? 1 - mid : mode == 1 ? (c.y + L.sizeZ / 2) / L.sizeZ : cityHash(i, j, k, 27, seed);
        H *= 1 + p.eq * spectrum(spec, saturate(u) * 0.85);
    }
    o.H = max(H, 0.0);
    o.empty = cityHash(i, j, k, 28, seed) < 0.04;

    float r4 = cityHash(i, j, k, 29, seed);
    o.tiers = 1;
    if (p.detail > 0.5) {
        if (o.H > 25 && r4 < p.setbacks) o.tiers = 2;
        if (o.H > 70 && r4 < p.setbacks * 0.7) o.tiers = 3;
    }
    float r5 = cityHash(i, j, k, 30, seed);
    o.h = o.tiers == 1 ? float3(o.H)
        : o.tiers == 2 ? float3(o.H * (0.45 + 0.2 * r5), o.H, o.H)
                       : float3(o.H * (0.3 + 0.15 * r5), o.H * (0.6 + 0.15 * r5), o.H);
    o.step = min(size.x, size.y) * (0.1 + 0.08 * r3) * p.setbacks;
    o.rand = cityHash(i, j, k, 31, seed);
    o.tone = p.wallTone + p.toneVar * (cityHash(i, j, k, 32, seed) - 0.5);
    return o;
}

// Off screen and zero-sized: a vertex this instance doesn't draw.
inline CityOut hidden(CityOut o) {
    o.position = float4(2, 2, 2, 1);
    return o;
}

inline float2 turn(float2 v, float a) { return float2(cos(a) * v.x - sin(a) * v.y, sin(a) * v.x + cos(a) * v.y); }

vertex CityOut gen_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device MeshVertex* verts [[buffer(0)]],
                          constant Frame& f [[buffer(1)]],
                          constant Params& p [[buffer(2)]],
                          constant Camera& cam [[buffer(3)]],
                          const device float4* sim [[buffer(4)]],
                          texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int part = int(v.shape.w + 0.5);
    int group = int(v.shape.y + 0.5);
    int slot = int(v.shape.z + 0.5);
    float extra = v.shape.x;
    float3 u = v.position.xyz;
    float3 n = v.faceNormal.xyz;
    Layout L = makeLayout(p);

    CityOut o;
    o.bary = v.bary.xyz;
    o.faceRand = v.position.w;
    o.rand = 0;
    o.tone = 0;
    o.state = 0;
    o.part = part;
    o.local = u;
    o.world = 0;
    o.m = 0;

    float3 pos;
    if (group == G_GROUND) {
        // The land and the river: instance 0 only.
        if (iid != 0) return hidden(o);
        bool water = extra > 0.5;
        if (water && L.river < 0.01) return hidden(o);
        float z0 = water ? L.waterZ0 : L.landZ0, z1 = water ? L.landZ0 : L.sizeZ / 2;
        pos = float3(mix(-L.sizeX / 2, L.sizeX / 2, u.x), mix(BASE_Y, water ? WATER_Y : 0.0, u.y), mix(z0, z1, u.z));
    } else {
        if (iid == 0) return hidden(o);
        int b = int(iid) - 1;
        int i = b % L.rows, j = b / L.rows;
        if (j >= L.cols) return hidden(o);
        float2 bm = blockMin(L, i, j);
        bool park = parkAt(i, j, p);
        float seed = seedOf(p);
        float fig = max(p.figures, 0.0);

        if (group == G_SLAB) {
            pos = float3(bm.x + u.x * L.bx, u.y * CURB_H, bm.y + u.z * L.bz);
            o.state = park ? 1 : 0;
        } else if (group == G_BUILDING) {
            if (park) return hidden(o);
            Lot lot = makeLot(L, i, j, slot, p, spec);
            if (lot.empty || lot.H < 0.01) return hidden(o);
            o.rand = lot.rand;
            o.tone = lot.tone;
            int top = lot.tiers - 1;
            float2 rlo = lot.lo + lot.step * top, rhi = lot.hi - lot.step * top;
            float2 rsize = rhi - rlo, rc = (rlo + rhi) * 0.5;
            float roofY = CURB_H + lot.H;
            if (part == WALL || part == ROOF) {
                int t = int(extra + 0.5);
                if (t >= lot.tiers) return hidden(o);
                float2 lo = lot.lo + lot.step * t, hi = lot.hi - lot.step * t;
                float y0 = t == 0 ? 0.0 : lot.h[t - 1];
                pos = float3(mix(lo.x, hi.x, u.x), CURB_H + mix(y0, lot.h[t], u.y), mix(lo.y, hi.y, u.z));
            } else if (part == LEDGE) {
                float2 lo = lot.lo - 0.4, hi = lot.hi + 0.4;
                float y1 = lot.h[0];
                pos = float3(mix(lo.x, hi.x, u.x), CURB_H + mix(max(y1 - 0.7, 0.0), y1, u.y), mix(lo.y, hi.y, u.z));
            } else if (part == SPIRE) {
                if (lot.H < 100 || cityHash(i, j, slot, 33, seed) > 0.7) return hidden(o);
                pos = float3(rc.x + u.x * 1.2, roofY + u.y * lot.H * 0.18, rc.y + u.z * 1.2);
            } else if (part == HVAC) {
                if (min(rsize.x, rsize.y) < 5 || cityHash(i, j, slot, 34, seed) > 0.8) return hidden(o);
                float2 at = rc + (float2(cityHash(i, j, slot, 35, seed), cityHash(i, j, slot, 36, seed)) - 0.5) * (rsize - 4) * 0.8;
                pos = float3(at.x + u.x, roofY + u.y, at.y + u.z);
            } else {
                // The water tower and its stand: on the lower buildings.
                if (lot.H > 90 || min(rsize.x, rsize.y) < 6 || cityHash(i, j, slot, 37, seed) > 0.65) return hidden(o);
                float2 at = rc - (float2(cityHash(i, j, slot, 35, seed), cityHash(i, j, slot, 36, seed)) - 0.5) * (rsize - 5) * 0.8;
                pos = float3(at.x + u.x, roofY + u.y, at.y + u.z);
            }
        } else if (group == G_TREE) {
            if (!park) return hidden(o);
            float2 lo = bm + L.side + 3, hi = bm + float2(L.bx, L.bz) - L.side - 3;
            float2 at = mix(lo, hi, float2(cityHash(i, j, slot, 40, seed), cityHash(i, j, slot, 41, seed)));
            float size = (0.7 + 0.6 * cityHash(i, j, slot, 42, seed)) * fig;
            pos = float3(at.x, CURB_H, at.y) + u * size;
            o.rand = cityHash(i, j, slot, 43, seed);
        } else if (group == G_LAMP) {
            if (!lampOn(i, j, slot, p)) return hidden(o);
            float2 at = lampPos(L, i, j, slot);
            pos = float3(at.x, CURB_H, at.y) + u * fig;
        } else if (group == G_SIGNAL) {
            float2 lo = bm + 0.6, hi = bm + float2(L.bx, L.bz) - 0.6;
            float2 at = float2(slot == 1 || slot == 2 ? hi.x : lo.x, slot >= 2 ? hi.y : lo.y);
            pos = float3(at.x, CURB_H, at.y) + u * fig;
            o.state = sim[0].x;
        } else if (group == G_CAR) {
            float4 car = sim[SIM_CARS + b * CARS_PER_BLOCK + slot];
            if (car.w == 0) return hidden(o);
            float size = abs(car.w) * fig;
            float2 xz = turn(u.xz * size, car.z);
            pos = float3(car.x + xz.x, u.y * size, car.y + xz.y);
            n = float3(turn(n.xz, car.z).x, n.y, turn(n.xz, car.z).y);
            o.state = car.w < 0 ? 1 : 0;
            o.rand = hash11(float(b * CARS_PER_BLOCK + slot) * 0.731 + 0.17);
        } else if (group == G_PERSON) {
            float4 person = sim[SIM_PEOPLE + b * PEOPLE_PER_BLOCK + slot];
            if (person.w < 0) return hidden(o);
            float3 l = u;
            if (part == LEGS) {
                // Swing each leg about the hip, one forward as the other goes back.
                float a = sin(person.w * M_PI_F / 0.75) * 0.45 * extra;
                float2 d = float2(l.x, l.y - 0.85);
                l.xy = float2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a) + 0.85);
            }
            float2 xz = turn(l.xz * fig, person.z);
            // On a sidewalk, or down on the road while crossing.
            float2 q = float2(posMod(person.x + L.sizeX / 2, L.pitchX), posMod(person.y + L.sizeZ / 2, L.pitchZ));
            float ground = q.x > L.sw && q.y > L.aw ? CURB_H : 0.0;
            pos = float3(person.x + xz.x, ground + l.y * fig, person.y + xz.y);
            n = float3(turn(n.xz, person.z).x, n.y, turn(n.xz, person.z).y);
            o.rand = hash11(float(b * PEOPLE_PER_BLOCK + slot) * 0.917 + 0.41);
        } else {
            // A pier into the river, off the waterfront blocks.
            if (j != 0 || L.river < 0.01 || cityHash(i, j, 0, 44, seed) > 0.6) return hidden(o);
            float cx = bm.x + L.bx * (0.3 + 0.4 * cityHash(i, j, 0, 45, seed));
            pos = float3(cx + (u.x - 0.5) * 6, mix(WATER_Y - 0.8, -0.1, u.y), mix(L.landZ0, L.landZ0 - L.river * 0.55, u.z));
        }
    }

    pos += n * p.explode * (0.3 + v.position.w) * 3;
    o.m = pos;
    o.world = pos * UNIT * p.scale;
    o.position = cam.viewProj * float4(o.world, 1);
    return o;
}

// A thin anti-aliased line at each whole number of g, fading out where it gets too fine to draw.
inline float gridLine(float g, float width) {
    float w = fwidth(g);
    float d = abs(fract(g + 0.5) - 0.5);
    return (1 - smoothstep(width, width + w * 1.5, d)) * saturate(1.2 - w * 3);
}

// 1 where x is within half-width hw of 0, anti-aliased.
inline float band(float x, float hw) {
    float w = fwidth(x);
    return 1 - smoothstep(hw - w, hw + w, abs(x));
}

// Stripes across x, `on` of each `period`, fading to their average where too fine.
inline float stripes(float x, float period, float on) {
    float q = x / period, w = fwidth(q);
    float s = smoothstep(0.5 - on * 0.5 - w, 0.5 - on * 0.5 + w, abs(fract(q) - 0.5));
    return mix(s, on, saturate(w * 2 - 0.5));
}

inline float3 background(texture2d<float> pal, float2 uv, float aspect, float time, constant Params& p) {
    float2 c = uv - 0.5;
    c.x *= aspect;
    float g = saturate(1 - length(c) * 1.1);
    float n = fbm3(float3(c * 2.5, time * 0.05));
    return paletteClamp(pal, 0.04 + 0.12 * (n * 0.5 + 0.5)) * p.bgGlow * (0.15 + 0.6 * g * g);
}

fragment float4 gen_fragment(CityOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    // Flat normal from screen-space derivatives: the low-poly look.
    float3 nrm = normalize(cross(dfdy(in.m), dfdx(in.m)));
    float3 V = normalize(cam.position.xyz - in.world);
    if (dot(nrm, V) < 0) nrm = -nrm;
    float3 Ldir = normalize(float3(-0.4, 0.85, 0.35));
    float diff = max(dot(nrm, Ldir), 0.0);
    float rim = pow(1 - saturate(dot(nrm, V)), 3.0);
    float bands = max(p.bands, 1.0);
    float shade = floor(saturate((diff * 0.75 + in.faceRand * 0.12 + 0.18) * p.light) * bands) / bands;

    Layout L = makeLayout(p);
    float3 lampColor = paletteClamp(pal, p.windowColor) * (0.6 + p.glow);
    float3 markColor = paletteClamp(pal, 0.9);
    float3 go = paletteClamp(pal, p.goColor) * (0.8 + p.glow), stop = paletteClamp(pal, p.stopColor) * (0.8 + p.glow);
    int part = in.part;
    float3 m = in.m;
    float3 col;

    // Where on the plan: which road, how far into it, how far from the nearest crossing. Worked out
    // for every pixel, as derivatives are, and masked in by part.
    float px = m.x + L.sizeX / 2, pz = m.z + L.sizeZ / 2;
    float fx = posMod(px, L.pitchX), fz = posMod(pz, L.pitchZ);
    bool tileZ = pz >= 0;
    bool onStreet = fx < L.sw, onAvenue = fz < L.aw && tileZ;
    // Avenues (along x): across from the centreline; the gap to the crossing either way.
    float avLat = fz - L.aw / 2, avAhead = L.pitchX - fx, avBehind = fx - L.sw;
    float stLat = fx - L.sw / 2, stAhead = L.pitchZ - fz, stBehind = fz - L.aw;
    float avLanes = float(lanesFor(L.aw)), stLanes = float(lanesFor(L.sw));
    float avLaneW = L.aw / 2 / avLanes, stLaneW = L.sw / 2 / stLanes;

    float avMarks = 0, stMarks = 0;
    {
        // Lane lines: a double centreline, dashed lines between lanes.
        float centre = max(band(avLat - 0.18, 0.06), band(avLat + 0.18, 0.06));
        float lane = band(posMod(avLat + avLaneW * 0.5, avLaneW) - avLaneW * 0.5, 0.07) * step(avLaneW * 0.5, abs(avLat))
                   * step(abs(avLat), L.aw / 2 - avLaneW * 0.5) * stripes(px, 9, 0.35);
        float toCross = min(avAhead, avBehind);
        float zebra = step(0.3, toCross) * stripes(avLat, 1.2, 0.5) * step(abs(avLat), L.aw / 2 - 0.4);
        // Stop lines, each side before the crossing its traffic meets.
        float stopLine = (avLat > 0 ? band(avAhead - L.cw - 0.3, 0.2) : band(avBehind - L.cw - 0.3, 0.2)) * step(abs(avLat), L.aw / 2 - 0.3);
        avMarks = toCross < L.cw - 0.3 ? zebra : max(stopLine, max(centre, lane) * step(L.cw + 0.6, toCross));
    }
    {
        float centre = max(band(stLat - 0.15, 0.05), band(stLat + 0.15, 0.05));
        float lane = band(posMod(stLat + stLaneW * 0.5, stLaneW) - stLaneW * 0.5, 0.07) * step(stLaneW * 0.5, abs(stLat))
                   * step(abs(stLat), L.sw / 2 - stLaneW * 0.5) * stripes(pz, 9, 0.35);
        float toCross = min(stAhead, stBehind);
        float zebra = step(0.3, toCross) * stripes(stLat, 1.2, 0.5) * step(abs(stLat), L.sw / 2 - 0.4);
        float stopLine = (stLat < 0 ? band(stAhead - L.cw - 0.3, 0.2) : band(stBehind - L.cw - 0.3, 0.2)) * step(abs(stLat), L.sw / 2 - 0.3);
        stMarks = toCross < L.cw - 0.3 ? zebra : max(stopLine, max(centre, lane) * step(L.cw + 0.6, toCross));
    }
    float pools = (part == LAND || part == SIDEWALK) ? lampPools(m.xz, L, p) : 0.0;
    float paving = max(gridLine(m.x / 1.5, 0.03), gridLine(m.z / 1.5, 0.03));

    // Windows, floor by floor, on upright faces, along whichever way the face runs.
    float fh = max(p.floorHeight, 0.5);
    float2 winQ = float2((abs(nrm.x) > abs(nrm.z) ? m.z : m.x) / 2.6, (m.y - CURB_H) / fh);
    float2 aa = fwidth(winQ);
    float2 cell = floor(winQ), fq = fract(winQ);
    float2 hs = float2(0.12 + 0.3 * p.windowSize, 0.12 + 0.3 * p.windowSize);
    float litShare = p.windows;
    if (cell.y < 0.5) { hs = float2(0.46, 0.32); litShare = saturate(p.windows * 1.8); }
    float2 d = abs(fq - 0.5) - hs;
    float box = (1 - smoothstep(-aa.x, aa.x, d.x)) * (1 - smoothstep(-aa.y, aa.y, d.y));
    float coverage = min(hs.x * 2, 1.0) * min(hs.y * 2, 1.0);
    float flick = floor(p.flickerPhase * 0.5 + hash21(cell + in.rand * 31.7) * 8);
    float on = step(hash31(float3(cell, in.rand * 113.1 + flick)), litShare);
    float near = saturate(1.2 - max(aa.x, aa.y) * 2.5);
    float upright = part == WALL && abs(nrm.y) < 0.4 ? 1.0 : 0.0;
    float glass = mix(coverage, box, near) * upright, lit = mix(coverage * litShare, box * on, near) * upright;

    if (part == LAND) {
        float3 asphalt = palette(pal, 0.07) * (0.5 + 0.5 * shade);
        if (!tileZ) {
            // The promenade along the river.
            col = palette(pal, 0.2) * (0.45 + 0.4 * shade);
            col = mix(col, palette(pal, 0.12), paving * 0.5);
        } else if (onStreet && onAvenue) {
            col = asphalt;
        } else if (onAvenue) {
            col = mix(asphalt, markColor, saturate(avMarks) * 0.85);
        } else if (onStreet) {
            col = mix(asphalt, markColor, saturate(stMarks) * 0.85);
        } else {
            col = palette(pal, 0.1) * (0.5 + 0.4 * shade);
        }
        col += lampColor * pools * 0.3;
    } else if (part == WATER) {
        // Ripples drifting downstream, broken up so they don't line up.
        float n = fbm3(float3(m.x * 0.04 - p.wavesPhase * 0.6, m.z * 0.12, p.wavesPhase * 0.2));
        float glint = smoothstep(0.55, 0.85, abs(sin(m.z * 0.6 + n * 6.0))) * smoothstep(0.0, 0.4, n + 0.2);
        col = palette(pal, p.waterColor) * (0.45 + 0.25 * shade) + paletteClamp(pal, 0.8) * (glint * 0.25 + rim * 0.2);
    } else if (part == BASE) {
        col = palette(pal, 0.06) * (0.35 + 0.4 * shade) + palette(pal, 0.12) * gridLine(m.y / 1.5, 0.04) * 0.3;
    } else if (part == SIDEWALK) {
        float2 b = float2(posMod(px - L.sw, L.pitchX), posMod(pz - L.aw, L.pitchZ));
        bool ring = b.x < L.side || b.y < L.side || b.x > L.bx - L.side || b.y > L.bz - L.side;
        if (ring) {
            col = palette(pal, 0.22) * (0.45 + 0.45 * shade);
            col = mix(col, palette(pal, 0.12), paving * 0.5);
        } else if (in.state > 0.5) {
            // A park: grass, with paths across it and round it.
            float2 c = b - float2(L.bx, L.bz) * 0.5;
            float path = max(band(abs(c.x) * L.bz / L.bx - abs(c.y), 1.2), band(min(min(b.x, b.y), min(L.bx - b.x, L.bz - b.y)) - L.side - 4, 1.0));
            col = palette(pal, p.parkColor) * (0.45 + 0.45 * shade);
            col = mix(col, palette(pal, 0.25) * (0.5 + 0.4 * shade), path);
        } else {
            col = palette(pal, 0.14) * (0.4 + 0.4 * shade);
        }
        col += lampColor * pools * 0.3;
    } else if (part == CURB) {
        col = palette(pal, 0.3) * (0.4 + 0.5 * shade);
    } else if (part == WALL) {
        col = palette(pal, in.tone) * (0.25 + 0.75 * shade);
        col = mix(col, palette(pal, 0.04) * 0.45 + paletteClamp(pal, 0.6) * rim * 0.25, glass);
        col = mix(col, lampColor * (0.8 + 0.4 * hash21(cell + 5.3 + in.rand)), lit);
    } else if (part == ROOF) {
        col = palette(pal, in.tone - 0.15) * (0.3 + 0.6 * shade);
        col = mix(col, palette(pal, in.tone - 0.25), gridLine(m.x / 3, 0.02) * 0.4);
    } else if (part == LEDGE) {
        col = palette(pal, in.tone + 0.15) * (0.35 + 0.75 * shade);
    } else if (part == TANK) {
        col = palette(pal, 0.32) * (0.35 + 0.6 * shade) * (1 - gridLine(in.local.y / 0.9, 0.05) * 0.4);
    } else if (part == HVAC) {
        col = palette(pal, 0.5) * (0.35 + 0.6 * shade);
    } else if (part == SPIRE) {
        // An aviation light blinking at the tip.
        col = palette(pal, 0.2) * (0.35 + 0.6 * shade);
        col += stop * step(0.88, in.local.y) * step(0.5, fract(f.time * 0.7 + in.rand));
    } else if (part == TRUNK) {
        col = palette(pal, 0.15) * (0.4 + 0.5 * shade);
    } else if (part == CROWN) {
        col = palette(pal, p.parkColor + (in.rand - 0.5) * 0.15) * (0.4 + 0.7 * shade);
    } else if (part == POST) {
        col = palette(pal, 0.12) * (0.35 + 0.6 * shade);
    } else if (part == LAMP) {
        col = lampColor * 1.3;
    } else if (part == SIGNAL) {
        // Facing along x for the avenues' traffic, along z for the streets'; red on top, green below.
        col = palette(pal, 0.05) * (0.4 + 0.3 * shade);
        float facing = abs(nrm.x) > 0.7 ? 1.0 : abs(nrm.z) > 0.7 ? 0.0 : -1.0;
        if (facing >= 0) {
            bool green = (facing > 0.5) == (in.state > 0.5);
            float upper = step(3.8, in.local.y);
            col += green ? go * (1 - upper) : stop * upper;
        }
    } else if (part == CAR) {
        float3 body = in.rand < p.taxis ? palette(pal, p.taxiColor)
                                        : palette(pal, p.carColor + (hash11(in.rand * 7.3) - 0.5) * 0.6);
        col = body * (0.35 + 0.75 * shade) + paletteClamp(pal, 1.0) * rim * 0.2;
        if (in.local.x > 2.15) col = lampColor * 1.2;
        else if (in.local.x < -2.15) col = stop * (in.state > 0.5 ? 1.3 : 0.4);
    } else if (part == CABIN) {
        col = palette(pal, 0.05) * (0.4 + 0.3 * shade) + paletteClamp(pal, 0.6) * rim * 0.35;
    } else if (part == SKIN) {
        col = palette(pal, 0.75) * (0.45 + 0.6 * shade);
    } else if (part == CLOTHES) {
        col = palette(pal, in.rand) * (0.4 + 0.7 * shade);
    } else if (part == LEGS) {
        col = palette(pal, 0.1) * (0.4 + 0.5 * shade);
    } else {
        // The pier's deck: planks.
        col = palette(pal, 0.28) * (0.4 + 0.5 * shade) * (1 - gridLine(m.z / 1.2, 0.05) * 0.35);
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

// Drawn behind the city. Alpha 0 marks background so feedback can trail behind geometry.
fragment float4 gen_background(FXOut in [[stage_in]],
                               texture2d<float> pal [[texture(0)]],
                               constant Frame& f [[buffer(0)]],
                               constant Params& p [[buffer(1)]]) {
    return float4(background(pal, in.uv, f.resolution.x / f.resolution.y, f.time, p), 0);
}
