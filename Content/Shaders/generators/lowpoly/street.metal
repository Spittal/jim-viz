// Street: walking down an endless street between low-poly buildings. The walker stands at the
// origin looking down -x, so a camera on +x (Static · Front) looks down the street; the street,
// lamps and buildings scroll past, and every lot builds itself anew each time it comes round,
// so the street never repeats. The street lies below the origin, which sits at eye height.
// @mesh street

// Inputs. Palette colours everything by position along it: the dark end is the road, glass
// and night sky, the middle the walls, the bright end the lit windows, lamps and accents (map
// a Palette's Colours into it). Spectrum raises the buildings, bass close by and treble far
// away (map Audio In's Spectrum).
// @palette pal Palette
// @spectrum spec Spectrum

// Walk: speed is how fast you walk, backwards below 0 (1 is walking pace). strafe steps across
// the street, from the left sidewalk (-1) to the right (1). bob is the head bobbing with each
// step. curves and hills bend and climb the street ahead; curveLength stretches them out.
// @group Walk
// @param speed 1 -10 10 rate
// @param strafe 0 -1 1
// @param bob 0.3 0 2
// @param curves 0 0 3
// @param curveLength 1 0.2 4
// @param hills 0 0 3

// Street: segments is how many slices the street is cut into; distance is how far ahead it goes,
// behind how far back. road and sidewalk are their widths in metres; lanes draws dashed lines
// between lanes. block is how many lots stand between cross streets (0: no cross streets).
// lamps is the share of lots with a street lamp.
// @group Street
// @param segments 64 8 256 int mesh
// @param distance 180 40 300
// @param behind 30 0 100
// @param road 10 0 30
// @param sidewalk 4 0 12
// @param lanes 2 1 6 int
// @param block 5 0 16 int
// @param lamps 0.5 0 1

// Buildings: detail adds rooftop clutter (1) and trims, fins, fire escapes and columns (2).
// style picks one architecture for the whole street, or Mixed for all of them; variety is the
// share of lots that ignore it and pick their own. seed reshuffles the street. lot is how far
// apart the buildings stand, gap the alleys between them; height, heightVar and footprint size
// them; setback pushes them back from the sidewalk by up to that many metres. twist turns the
// Twisted towers' floors. rise sinks the buildings far away into the ground, so they grow as you
// come toward them.
// @group Buildings
// @param detail 2 0 2 int mesh
// @param style 0 0 11 int Mixed,Blocks,Deco,Townhouse,Tenement,Pagoda,Dome,Brutalist,Twisted,Warehouse,Crystal,Gothic
// @param variety 0.3 0 1
// @param seed 0 0 99 int
// @param lot 16 6 40
// @param gap 0.15 0 0.8
// @param height 30 0 120
// @param heightVar 0.5 0 1
// @param footprint 18 2 60
// @param setback 1 0 10
// @param twist 1 -2 2
// @param rise 0 0 1

// Windows: windows is the share lit; floorHeight spaces the floors (and the windows with them);
// windowSize opens them up. flicker switches lights on and off. windowColor picks the lit
// windows' and lamps' place on the palette; glow is how bright they shine.
// @group Windows
// @param windows 0.35 0 1
// @param floorHeight 3.5 1 10
// @param windowSize 0.6 0 1
// @param flicker 0 0 4 rate
// @param windowColor 1 0 1
// @param glow 1 0 3

// Look: wallTone picks the walls' place on the palette, toneVar how far each building strays
// from it. wire draws every edge; bands steps the shading; fog fades the distance into the sky;
// bgGlow is the sky. explode shatters the whole street along its faces.
// @group Look
// @param wallTone 0.4 0 1
// @param toneVar 0.25 0 1
// @param wire 0 0 1
// @param bands 5 1 16 int
// @param light 1.1 0 3
// @param fog 1 0 4
// @param bgGlow 1 0 2
// @param explode 0 0 4

// Audio: eq is how far the spectrum raises the buildings.
// @group Spectrum spec
// @param eq 0 0 3

// Layout must match MeshVertex in Render/Mesh.swift.
struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
    float4 shape;        // y = style, w = part; see Render/StreetMesh.swift
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

// Parts and styles, matching StreetPart and StreetStyle in Render/StreetMesh.swift.
constant int ROAD = 0, CURB = 1, SIDEWALK = 2, GROUND = 3, WALL = 4, ROOF = 5, TRIM = 6, GLASS = 7,
             ACCENT = 8, DARK = 9, POST = 10, LAMP = 11;
constant int STYLES = 11, LAMP_STYLE = 11;
// Each style's height, against the height knob.
constant float STYLE_HEIGHT[11] = {1.0, 1.5, 0.32, 0.5, 0.7, 0.55, 0.8, 1.7, 0.3, 1.8, 0.9};
// How each style's walls take windows: 0 ribbons, 1 punched, 2 tall strips, 3 curtain wall,
// 4 factory grid.
constant int STYLE_WINDOWS[11] = {0, 2, 1, 1, 1, 1, 0, 3, 4, 3, 2};

constant float METRES_PER_SPEED = 1.5; // a second at speed 1: walking pace
constant float STREET_Y = -1.6;        // the road's height: the origin is at eye height
constant float CURB_HEIGHT = 0.15;
constant float STRIDE = 0.8;           // metres a step, for bob
constant float LAMP_OUT = 0.45;        // the lamp posts' distance back from the road's edge

struct StreetOut {
    float4 position [[position]];
    float3 world;
    float3 bary;
    float3 local;              // buildings: metres in the lot (along, up, back), before twist;
                               // the street: (distance ahead, across, side)
    float faceRand [[flat]];
    float lotRand [[flat]];
    float tone [[flat]];
    int part [[flat]];
    int style [[flat]];
};

// x mod m, always 0...m, so walking backwards scrolls the same way.
inline float posMod(float x, float m) { return x - floor(x / m) * m; }

// The street's centreline: a sideways bend and a height along it, each taken relative to its
// tangent where the walker stands, so the street underfoot is level and straight ahead.
struct Street {
    float T;       // distance walked
    float k, A;    // bend wavenumber and size
    float kh, Ah;  // hill wavenumber and size
    float rw, sw;  // half the road's width, the sidewalk's
    float far, back;
    float lot, lots;
};

inline Street makeStreet(constant Params& p) {
    Street s;
    s.T = p.speedPhase * METRES_PER_SPEED;
    s.k = 1 / (60 * max(p.curveLength, 0.05));
    s.A = 10 * p.curves;
    s.kh = 1 / (45 * max(p.curveLength, 0.05));
    s.Ah = 3 * p.hills;
    s.rw = p.road * 0.5;
    s.sw = p.sidewalk;
    s.far = p.distance;
    s.back = p.behind;
    s.lot = max(p.lot, 1.0);
    // Must match streetLots in Render/StreetMesh.swift, which sets the instance count.
    s.lots = clamp(ceil((p.distance + p.behind) / s.lot - 0.01), 1.0, 128.0);
    return s;
}

inline float wave(float u, float k) { return sin(u * k) + 0.5 * sin(u * k * 2.31 + 1.7); }
inline float waveD(float u, float k) { return k * (cos(u * k) + 1.155 * cos(u * k * 2.31 + 1.7)); }

inline float bendAt(Street r, float s) { return r.A * (wave(r.T + s, r.k) - wave(r.T, r.k) - s * waveD(r.T, r.k)); }
inline float bendSlope(Street r, float s) { return r.A * (waveD(r.T + s, r.k) - waveD(r.T, r.k)); }
inline float hillAt(Street r, float s) {
    return r.Ah * (wave(r.T + s, r.kh * 1.37) - wave(r.T, r.kh * 1.37) - s * waveD(r.T, r.kh * 1.37));
}

// Lot g's building has a cross street through it instead, every block + 1 lots.
inline bool crossingAt(float g, constant Params& p) {
    float n = round(p.block);
    return n > 0.5 && posMod(g, n + 1) > n - 0.5;
}

inline float lotHash(float g, float side, float n, constant Params& p) {
    return hash31(float3(g * 1.013 + 0.37, side * 3.1 + n * 7.7, round(p.seed) * 13.17 + n * 1.9));
}

inline bool lampAt(float g, float side, constant Params& p) {
    return !crossingAt(g, p) && lotHash(g, side, 11, p) < p.lamps;
}

// Off screen and zero-sized: a vertex this instance doesn't draw.
inline StreetOut hidden(StreetOut o) {
    o.position = float4(2, 2, 2, 1);
    return o;
}

vertex StreetOut gen_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device MeshVertex* verts [[buffer(0)]],
                            constant Frame& f [[buffer(1)]],
                            constant Params& p [[buffer(2)]],
                            constant Camera& cam [[buffer(3)]],
                            texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int part = int(v.shape.w + 0.5);
    int style = int(floor(v.shape.y + 0.5));
    Street st = makeStreet(p);

    StreetOut o;
    o.bary = v.bary.xyz;
    o.faceRand = v.position.w;
    o.lotRand = 0;
    o.tone = 0;
    o.part = part;
    o.style = style;
    o.local = 0;
    o.world = 0;

    float3 pos, nrm;
    if (style < 0) {
        // The street: instance 0 only.
        if (iid != 0) return hidden(o);
        float L = st.far + st.back;
        float segLen = L / clamp(round(p.segments), 8.0, 512.0);
        float s = v.position.x * L - st.back - posMod(st.T, segLen);
        float a = v.position.z, side = v.shape.x;
        float lat, y = CURB_HEIGHT;
        if (part == ROAD) {
            lat = a * st.rw;
            y = 0;
        } else if (part == CURB) {
            lat = side * st.rw;
            y = v.position.y * CURB_HEIGHT;
        } else if (part == SIDEWALK) {
            lat = side * (st.rw + a * st.sw);
        } else {
            lat = side * (st.rw + st.sw + a * (p.footprint * 1.6 + p.setback + 60));
        }
        float b = bendSlope(st, s);
        float3 across = normalize(float3(b, 0, 1));
        pos = float3(-s, hillAt(st, s) + y, bendAt(st, s)) + across * lat;
        nrm = part == CURB ? across * -side : float3(0, 1, 0);
        o.local = float3(s, lat, side);
    } else {
        // A lot: instances 1... alternate sides. Lot i comes round every lots × lot metres, and
        // g counts lots along the whole street, so each time round it is a new lot.
        if (iid == 0) return hidden(o);
        uint k = iid - 1;
        float i = float(k / 2), side = (k % 2) ? 1.0 : -1.0;
        float C = st.lots * st.lot;
        float q = (i + 0.5) / st.lots - st.T / C;
        float lap = floor(q);
        float sc = (q - lap) * C - st.back;
        float g = i - lap * st.lots;
        if (crossingAt(g, p)) return hidden(o);

        float3 L;
        float offset;
        if (style == LAMP_STYLE) {
            if (!lampAt(g, side, p)) return hidden(o);
            L = float3(v.position.x, v.position.y + v.shape.x, v.position.z);
            o.local = L;
            offset = st.rw + LAMP_OUT;
        } else {
            int pick = min(int(lotHash(g, side, 0, p) * STYLES), STYLES - 1);
            int chosen = p.style < 0.5 || lotHash(g, side, 1, p) < p.variety ? pick : int(round(p.style)) - 1;
            if (style != chosen) return hidden(o);
            float W = st.lot * (1 - p.gap * (0.3 + 0.7 * lotHash(g, side, 2, p)));
            float H = p.height * STYLE_HEIGHT[style] * max(1 + p.heightVar * (lotHash(g, side, 3, p) * 2 - 1), 0.05);
            float D = p.footprint * (0.75 + 0.5 * lotHash(g, side, 4, p));
            float setback = p.setback * lotHash(g, side, 5, p);
            float uOff = (st.lot - W) * (lotHash(g, side, 6, p) - 0.5);
            if (p.eq > 0) H *= 1 + p.eq * spectrum(spec, saturate((sc + st.back) / (st.far + st.back)) * 0.85);
            float grow = 1 - p.rise * smoothstep(0.3, 1.0, sc / st.far);

            L = float3(v.position.x * W + uOff, (v.position.y * H + v.shape.x * W) * grow, v.position.z * D);
            o.local = L;
            if (v.shape.z != 0) {
                float2 c = rot2(p.twist * v.shape.z * M_PI_F * 0.5) * float2(L.x - uOff, L.z - D * 0.5);
                L.x = c.x + uOff;
                L.z = c.y + D * 0.5;
            }
            offset = st.rw + st.sw + setback;
            o.lotRand = lotHash(g, side, 7, p);
            o.tone = p.wallTone + p.toneVar * (lotHash(g, side, 8, p) - 0.5);
        }

        // Stand the lot square to the street where it stands, facing the street.
        float b = bendSlope(st, sc);
        float3 along = normalize(float3(-1, 0, b)), across = normalize(float3(b, 0, 1));
        float3 base = float3(-sc, hillAt(st, sc) + CURB_HEIGHT, bendAt(st, sc));
        pos = base + along * L.x + across * (side * (offset + L.z)) + float3(0, L.y, 0);
        float3 n = v.faceNormal.xyz;
        nrm = along * n.x + float3(0, n.y, 0) + across * (side * n.z);
    }

    pos += nrm * p.explode * (0.3 + v.position.w) * 2;

    // The walker: down at the street, stepped across it, bobbing and swaying with each step.
    float ph = st.T * M_PI_F / STRIDE;
    pos += float3(0, STREET_Y - p.bob * 0.06 * abs(sin(ph)), -p.strafe * (st.rw + st.sw * 0.5) - p.bob * 0.03 * sin(ph));

    o.world = pos;
    o.position = cam.viewProj * float4(pos, 1);
    return o;
}

// The sky's colour at height h above the horizon (0) up to the top (1). Fog fades to h = 0.
inline float3 sky(texture2d<float> pal, float h, constant Params& p) {
    h = saturate(h);
    return paletteClamp(pal, 0.3 * (1 - h) * (1 - h)) * p.bgGlow * mix(0.8, 0.2, h);
}

// A thin anti-aliased line at each whole number of g, fading out where it gets too fine to draw.
inline float gridLine(float g, float width) {
    float w = fwidth(g);
    float d = abs(fract(g + 0.5) - 0.5);
    return (1 - smoothstep(width, width + w * 1.5, d)) * saturate(1.2 - w * 3);
}

// 1 inside a box of half-size hs round c in cell coordinates fq, softened by aa.
inline float boxMask(float2 fq, float2 c, float2 hs, float2 aa) {
    float2 d = abs(fq - c) - hs;
    return (1 - smoothstep(-aa.x, aa.x, d.x)) * (1 - smoothstep(-aa.y, aa.y, d.y));
}

fragment float4 gen_fragment(StreetOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    // Flat normal from screen-space derivatives: the low-poly look.
    float3 nrm = normalize(cross(dfdy(in.world), dfdx(in.world)));
    float3 V = normalize(cam.position.xyz - in.world);
    if (dot(nrm, V) < 0) nrm = -nrm;
    float3 Ldir = normalize(float3(-0.45, 0.75, 0.5));
    float diff = max(dot(nrm, Ldir), 0.0);
    float rim = pow(1 - saturate(dot(nrm, V)), 3.0);
    float bands = max(p.bands, 1.0);
    float shade = floor(saturate((diff * 0.75 + in.faceRand * 0.15 + 0.15) * p.light) * bands) / bands;

    Street st = makeStreet(p);
    float3 lampColor = paletteClamp(pal, p.windowColor) * (0.6 + p.glow);
    float3 asphalt = palette(pal, 0.08) * (0.5 + 0.5 * shade);
    float3 col;
    float fogAmount = 1;
    int part = in.part;

    // The street's lot g spans [g, g + 1) of A, the whole way along it.
    float s = in.local.x, lat = in.local.y, side = in.local.z;
    float A = (s + st.back + st.T) / st.lot;
    float g = floor(A), fl = A - g;
    float crossHalf = min(st.rw * 2, st.lot * 0.8) * 0.5 / st.lot;
    bool crossLot = crossingAt(g, p);
    bool inCross = crossLot && abs(fl - 0.5) < crossHalf;

    if (part == ROAD || (part <= GROUND && inCross)) {
        col = asphalt;
    } else if (part == CURB) {
        col = palette(pal, 0.3) * (0.4 + 0.6 * shade);
    } else if (part == SIDEWALK) {
        col = palette(pal, 0.22) * (0.4 + 0.5 * shade);
    } else if (part == GROUND) {
        col = palette(pal, 0.06) * (0.4 + 0.4 * shade);
    } else if (part == WALL) {
        col = palette(pal, in.tone) * (0.25 + 0.75 * shade);
    } else if (part == GLASS) {
        col = palette(pal, 0.05) * (0.4 + 0.4 * shade) + paletteClamp(pal, 0.6) * rim * 0.3;
    } else if (part == ROOF) {
        col = palette(pal, in.tone - 0.12) * (0.2 + 0.7 * shade);
    } else if (part == TRIM) {
        col = palette(pal, in.tone + 0.18) * (0.3 + 0.8 * shade);
    } else if (part == ACCENT) {
        col = paletteClamp(pal, 0.85) * (0.4 + 0.8 * shade) + paletteClamp(pal, 1.0) * rim * 0.4;
    } else if (part == DARK) {
        col = palette(pal, 0.03) * (0.4 + 0.3 * shade);
    } else if (part == POST) {
        col = palette(pal, 0.12) * (0.3 + 0.7 * shade);
    } else {
        col = lampColor * 1.3;
        fogAmount = 0.5;
    }

    // Markings and windows use derivatives, which are undefined where neighbouring pixels take
    // different branches (and the compiler moves them into branches), so they are worked out
    // for every pixel and masked in by part.
    float3 markColor = paletteClamp(pal, 0.9);
    float onStreet = part <= GROUND ? 1.0 : 0.0;

    // Dashed lines between lanes.
    float hw = max(st.rw, 1e-3), lanes = max(round(p.lanes), 1.0);
    float laneQ = (lat / hw * 0.5 + 0.5) * lanes, edge = round(laneQ);
    float lineWidth = 0.08 / (2 * hw / lanes);
    float laneLine = 1 - smoothstep(lineWidth, lineWidth + fwidth(laneQ), abs(laneQ - edge));
    laneLine *= step(fract((s + st.T) / 6), 0.5) * step(0.5, edge) * step(edge, lanes - 0.5);
    col = mix(col, markColor, laneLine * (part == ROAD && !inCross ? 1.0 : 0.0));

    // Zebra crossings either side of a cross street.
    float zq = lat / 1.2, zw = fwidth(zq);
    float zebra = smoothstep(0.5 - zw, 0.5 + zw, fract(zq)) * saturate(1.2 - zw * 3);
    float dz = abs(fl - 0.5) - crossHalf;
    bool atZebra = part == ROAD && crossLot && dz > 0 && dz < 3 / st.lot && abs(lat) < st.rw - 0.3;
    col = mix(col, markColor * 0.9, zebra * (atZebra ? 1.0 : 0.0));

    // Paving joints.
    float joint = max(gridLine((s + st.T) / 2, 0.03), gridLine((lat - side * st.rw) / 2, 0.03));
    col = mix(col, palette(pal, 0.1), joint * 0.6 * (part == SIDEWALK && !inCross ? 1.0 : 0.0));

    // A pool of light under this lot's lamp on each side.
    float pool = 0;
    for (int k = 0; k < 2; k++) {
        float sd = k == 0 ? -1.0 : 1.0;
        float2 dl = float2((fl - 0.5) * st.lot, lat - sd * (st.rw + LAMP_OUT - 1.45));
        pool += exp(-dot(dl, dl) / 10) * (lampAt(g, sd, p) ? 1.0 : 0.0);
    }
    col += lampColor * min(pool, 1.0) * 0.35 * onStreet;

    // Windows, floor by floor, on upright faces, in the building's own metres along whichever
    // way the face runs.
    float3 lp = in.local;
    float3 ln = normalize(cross(dfdy(lp), dfdx(lp)));
    int type = STYLE_WINDOWS[clamp(in.style, 0, STYLES - 1)];
    float fh = max(p.floorHeight, 0.5);
    float cellW = type == 4 ? fh * 1.4 : type == 2 ? fh * 0.6 : fh * 0.85;
    float2 winQ = float2((abs(ln.x) > abs(ln.z) ? lp.z : lp.x) / cellW, lp.y / fh);
    float2 aa = fwidth(winQ);
    float2 c = floor(winQ), fq = fract(winQ);
    float ws = p.windowSize;
    float2 hs = type == 0 ? float2(0.6, 0.1 + 0.3 * ws)
              : type == 1 ? float2(0.1 + 0.3 * ws, 0.12 + 0.28 * ws)
              : type == 2 ? float2(0.08 + 0.25 * ws, 0.25 + 0.24 * ws)
              : type == 3 ? float2(0.42 + 0.07 * ws, 0.42 + 0.07 * ws)
                          : float2(0.15 + 0.33 * ws, 0.15 + 0.3 * ws);
    float cy = 0.55, litShare = p.windows;
    if (c.y < 0.5 && type <= 2) {
        // Shopfronts on the ground floor.
        hs = float2(0.46, 0.3);
        cy = 0.42;
        litShare = saturate(p.windows * 1.8);
    }
    float coverage = min(hs.x * 2, 1.0) * min(hs.y * 2, 1.0);
    float m = boxMask(fq, float2(0.5, cy), hs, aa);
    float flick = floor(p.flickerPhase * 0.5 + hash21(c + in.lotRand * 31.7) * 8);
    float on = step(hash31(float3(c, in.lotRand * 113.1 + flick)), litShare);
    // Too small to draw: the average.
    float near = saturate(1.2 - max(aa.x, aa.y) * 2.5);
    float hasWindows = (part == WALL || part == GLASS) && abs(ln.y) < 0.4 && lp.y > 0.2 ? 1.0 : 0.0;
    float glass = mix(coverage, m, near) * hasWindows, lit = mix(coverage * litShare, m * on, near) * hasWindows;
    col = mix(col, palette(pal, 0.04) * 0.45 + paletteClamp(pal, 0.6) * rim * 0.25, glass);
    col = mix(col, lampColor * (0.8 + 0.4 * hash21(c + 5.3 + in.lotRand)), lit);

    // Wireframe from barycentrics.
    float e = min(min(in.bary.x, in.bary.y), in.bary.z);
    float w = 1 - smoothstep(0.0, fwidth(e) * 1.5, e);
    col = mix(col, paletteClamp(pal, 1.0) * 1.4, w * p.wire);

    // Fog toward the horizon.
    float dist = length(cam.position.xyz - in.world);
    col = mix(col, sky(pal, 0, p), (1 - exp(-dist * p.fog * 2.5 / max(p.distance, 1.0))) * fogAmount);
    return float4(col, 1);
}

// The sky behind everything: dark at the top, glowing toward the horizon, with stars. The
// horizon is where the camera sees the far distance, ahead or behind. Alpha 0 marks background so
// feedback can trail behind geometry.
fragment float4 gen_background(FXOut in [[stage_in]],
                               texture2d<float> pal [[texture(0)]],
                               constant Frame& f [[buffer(0)]],
                               constant Params& p [[buffer(1)]],
                               constant Camera& cam [[buffer(2)]]) {
    float aspect = f.resolution.x / f.resolution.y;
    float2 ndc = float2(in.uv.x * 2 - 1, 1 - in.uv.y * 2);
    float h = 1 - in.uv.y;
    // Down the street (-x), or behind (+x) when the camera looks back.
    float dx = (cam.viewProj * float4(-1, 0, 0, 0)).w > 0 ? -1 : 1;
    float4 a = cam.viewProj * float4(dx, 0, -0.3, 0), b = cam.viewProj * float4(dx, 0, 0.3, 0);
    float4 up = cam.viewProj * float4(dx, 0.3, 0, 0);
    if (a.w > 1e-4 && b.w > 1e-4 && up.w > 1e-4) {
        float2 na = a.xy / a.w * float2(aspect, 1), nb = b.xy / b.w * float2(aspect, 1);
        float2 nu = up.xy / up.w * float2(aspect, 1);
        float2 d = normalize(nb - na + 1e-6);
        float2 n = float2(-d.y, d.x);
        if (dot(nu - na, n) < 0) n = -n;
        h = dot(ndc * float2(aspect, 1) - na, n) * 0.6;
    }
    float3 col = sky(pal, h, p);

    // Stars, twinkling, thinning toward the horizon.
    float2 cell = floor(in.uv * float2(aspect, 1) * 140);
    float star = step(0.994, hash21(cell)) * saturate(h * 2 - 0.2);
    star *= 0.5 + 0.5 * sin(f.time * (1 + hash21(cell + 7) * 3) + hash21(cell + 3) * 6.28);
    col += paletteClamp(pal, 1.0) * star * 0.6 * p.bgGlow;
    return float4(col, 0);
}
