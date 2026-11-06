// Drive: a low-poly 80s wedge car with pinstripes, driving down an endless road toward a
// sliced sun. The car sits at the origin facing -x, so a camera on +x (Static · Front) chases
// it. The road, rumble strips, gridded ground and palms scroll past; the road bends and climbs
// ahead and the mountains and sun swing across the horizon as it turns.
// @mesh drive

// Inputs. Palette colours everything by position along it: the dark end is the ground, road
// and night sky, the bright end the sun, stripes and road lines (map a Palette's Colours into
// it). Spectrum raises the mountains and the ground's outer edges (map Audio In's Spectrum).
// @palette pal Palette
// @spectrum spec Spectrum

// Drive: speed is how fast the road comes at you. curves and hills are how hard the road bends
// and climbs ahead; curveLength stretches them out. lane moves the car across the road, from
// left (-1) to right (1) seen from behind. steer is how far the car turns and leans into the
// bends; bounce lifts it off the road (map a kick here).
// @group Drive
// @param speed 1 0 8 rate
// @param curves 1 0 3
// @param curveLength 1 0.2 4
// @param hills 0.5 0 3
// @param lane 0 -1 1
// @param steer 1 0 3
// @param bounce 0 0 1

// Road: segments is how many slices the road is cut into (each rumble block is one); distance
// is how far ahead of the car it goes, behind how far back past it. lanes draws dashed lines
// between lanes. grid lights the ground's grid lines, gridSize spaces them.
// @group Road
// @param segments 72 8 256 int mesh
// @param distance 140 40 210
// @param behind 40 0 100
// @param width 8 0 24
// @param lanes 2 1 6 int
// @param rumble 0.6 0 3
// @param grid 0.6 0 1
// @param gridSize 4 0.5 16

// Scenery: palms is how many line the road, alternating sides. mountains is the range's
// height, sun the sun's size; sunSlices opens the gaps across its lower half; sunHeight lifts
// it over the horizon.
// @group Scenery
// @param palms 24 0 128 int mesh
// @param palmSize 1 0 3
// @param mountains 1 0 3
// @param sun 1 0 2
// @param sunSlices 0.6 0 1
// @param sunHeight 0.15 -0.5 1

// Car: carColor and stripeColor pick their places on the palette; lights is the tail light glow.
// @group Car
// @param carSize 1 0 3
// @param carColor 0.75 0 1
// @param stripeColor 1 0 1
// @param lights 1 0 3

// Look: wire draws every edge; bands steps the shading; fog fades the distance into the
// horizon; bgGlow is the sky. explode shatters the whole world along its faces.
// @group Look
// @param wire 0 0 1
// @param bands 5 1 16 int
// @param light 1.1 0 3
// @param fog 1 0 4
// @param bgGlow 1 0 2
// @param explode 0 0 4

// Audio: eq is how far the spectrum raises the mountains and the ground's outer edges.
// @group Audio spec
// @param eq 0 0 3

// Layout must match MeshVertex in Render/Mesh.swift.
struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
    float4 shape;        // w = part; see Render/DriveMesh.swift
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

// Parts, matching DrivePart in Render/DriveMesh.swift.
constant int ROAD = 0, RUMBLE = 1, GROUND = 2, BODY = 3, STRIPE = 4, GLASS = 5, LIGHT = 6,
             WHEEL = 7, TRUNK = 8, FROND = 9, SUN = 10, MOUNTAIN = 11;

constant float UNITS_PER_SPEED = 30; // road units a second at speed 1
constant float WHEEL_RADIUS = 0.34;

struct DriveOut {
    float4 position [[position]];
    float3 world;
    float3 bary;
    float2 road;              // along and across the road, for its markings and the ground grid
    float faceRand [[flat]];
    int part [[flat]];
};

// The road's shape, as a sideways bend and a height along an endless centreline. Each is
// taken relative to its tangent at the car, so the road under the car is always level and
// straight ahead, and only bends away in front.
struct Road {
    float T;      // distance travelled
    float k, A;   // bend wavenumber and size
    float kh, Ah; // hill wavenumber and size
};

inline Road makeRoad(constant Params& p) {
    Road r;
    r.T = p.speedPhase * UNITS_PER_SPEED;
    r.k = 1 / (40 * max(p.curveLength, 0.05));
    r.A = 12 * p.curves;
    r.kh = 1 / (30 * max(p.curveLength, 0.05));
    r.Ah = 3 * p.hills;
    return r;
}

inline float wave(float u, float k) { return sin(u * k) + 0.5 * sin(u * k * 2.31 + 1.7); }
inline float waveD(float u, float k) { return k * (cos(u * k) + 1.155 * cos(u * k * 2.31 + 1.7)); }
inline float waveDD(float u, float k) { return -k * k * (sin(u * k) + 2.668 * sin(u * k * 2.31 + 1.7)); }

inline float bendAt(Road r, float s) { return r.A * (wave(r.T + s, r.k) - wave(r.T, r.k) - s * waveD(r.T, r.k)); }
inline float hillAt(Road r, float s) {
    return r.Ah * (wave(r.T + s, r.kh * 1.37) - wave(r.T, r.kh * 1.37) - s * waveD(r.T, r.kh * 1.37));
}

vertex DriveOut gen_vertex(uint vid [[vertex_id]],
                           const device MeshVertex* verts [[buffer(0)]],
                           constant Frame& f [[buffer(1)]],
                           constant Params& p [[buffer(2)]],
                           constant Camera& cam [[buffer(3)]],
                           texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int part = int(v.shape.w + 0.5);
    Road r = makeRoad(p);
    float far = p.distance, back = p.behind, L = far + back;
    float hw = p.width * 0.5, rw = p.rumble;
    // Heading swings the horizon the opposite way to the turn.
    float swing = -far * r.A * waveD(r.T, r.k);
    float3 pos;
    float2 road = 0;

    if (part <= GROUND) {
        float segLen = L / clamp(round(p.segments), 8.0, 512.0);
        float s = v.position.x * L - back - fmod(r.T, segLen);
        float a = v.position.z, side = v.shape.y;
        float lat = part == ROAD ? a * hw : part == RUMBLE ? side * (hw + a * rw) : side * (hw + rw + a * a * L * 0.8);
        float y = hillAt(r, s);
        if (part == GROUND && p.eq > 0) y += p.eq * spectrum(spec, a * 0.85) * a * 12;
        pos = float3(-s, y, bendAt(r, s) + lat);
        road = float2(s, lat);
    } else if (part <= WHEEL) {
        float3 c = v.position.xyz;
        if (part == WHEEL) {
            c.xy = rot2(fmod(r.T, 2 * M_PI_F * WHEEL_RADIUS) / WHEEL_RADIUS) * c.xy;
            c += v.shape.xyz;
        }
        c *= p.carSize;
        // Lean out of the bend and turn into it.
        float bend = r.A * waveDD(r.T, r.k) * p.steer;
        c.yz = rot2(-bend * 3) * c.yz;
        c.xz = rot2(-bend * 8) * c.xz;
        c.y += p.bounce * 0.4 * p.carSize + sin(f.time * 37) * 0.006 * p.carSize * min(p.speed, 1.0);
        c.z -= p.lane * max(hw - 1.0 * p.carSize, 0.0);
        pos = c;
    } else if (part <= FROND) {
        float s = fract(v.shape.x - r.T / L) * L - back;
        float side = v.shape.y, rnd = v.shape.z;
        float3 c = v.position.xyz * p.palmSize * (0.8 + 0.5 * rnd);
        if (part == FROND) c.y += sin(f.time * 1.3 + rnd * 20 + c.x) * 0.08 * length(c.xz);
        c.z *= side;
        float lat = side * (hw + rw + 3 + rnd * 6);
        pos = float3(-s, hillAt(r, s), bendAt(r, s) + lat) + c;
    } else if (part == SUN) {
        float centre = v.shape.x, halfHeight = v.shape.y;
        float gap = p.sunSlices * saturate((0.5 - centre) / 1.5);
        float y = centre + v.position.y * halfHeight * (1 - gap);
        float x = v.position.x * sqrt(max(1 - y * y, 0.0));
        float radius = far * 0.17 * p.sun;
        pos = float3(-far * 1.12, (y + 2 * p.sunHeight) * radius, x * radius + swing * 1.12);
        road = float2(0, y);
    } else {
        float across = v.position.x, h = v.position.y, depth = v.position.z;
        float lift = p.mountains + p.eq * spectrum(spec, (across * 0.5 + 0.5) * 0.85);
        pos = float3(-far * (1 + depth * 0.06), h * lift * far * 0.2 - 1, across * far * 1.6 + swing);
    }

    pos += v.faceNormal.xyz * p.explode * (0.3 + v.position.w) * 2;

    DriveOut o;
    o.world = pos;
    o.position = cam.viewProj * float4(pos, 1);
    o.bary = v.bary.xyz;
    o.road = road;
    o.faceRand = v.position.w;
    o.part = part;
    return o;
}

// The sky's colour at height h above the horizon (0) up to the top (1). Fog fades to h = 0.
inline float3 sky(texture2d<float> pal, float h, constant Params& p) {
    h = saturate(h);
    return paletteClamp(pal, 0.42 * (1 - h) * (1 - h)) * p.bgGlow * mix(0.9, 0.25, h);
}

// A thin anti-aliased line at each whole number of g, fading out where it gets too fine to draw.
inline float gridLine(float g, float width) {
    float w = fwidth(g);
    float d = abs(fract(g + 0.5) - 0.5);
    return (1 - smoothstep(width, width + w * 1.5, d)) * saturate(1.2 - w * 3);
}

fragment float4 gen_fragment(DriveOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    // Flat normal from screen-space derivatives: the low-poly look.
    float3 nrm = normalize(cross(dfdy(in.world), dfdx(in.world)));
    float3 V = normalize(cam.position.xyz - in.world);
    if (dot(nrm, V) < 0) nrm = -nrm;
    float3 Ldir = normalize(float3(-0.7, 0.6, 0.25)); // from the sun, low ahead
    float diff = max(dot(nrm, Ldir), 0.0);
    float rim = pow(1 - saturate(dot(nrm, V)), 3.0);
    float bands = max(p.bands, 1.0);
    float shade = floor(saturate((diff * 0.75 + in.faceRand * 0.15 + 0.1) * p.light) * bands) / bands;

    Road r = makeRoad(p);
    float segLen = (p.distance + p.behind) / clamp(round(p.segments), 8.0, 512.0);
    float along = in.road.x + fmod(r.T, 2 * segLen);
    // fract, not fmod: behind the car along is negative, and fmod would keep the sign.
    bool odd = fract(floor(along / segLen) * 0.5) > 0.25;

    float3 col;
    float fogAmount = 1;
    int part = in.part;
    if (part == ROAD) {
        col = palette(pal, odd ? 0.1 : 0.14) * (0.5 + 0.5 * shade);
        float hw = max(p.width * 0.5, 1e-3), lanes = max(round(p.lanes), 1.0);
        float q = (in.road.y / hw * 0.5 + 0.5) * lanes;
        float edge = round(q);
        float lineWidth = 0.1 / (2 * hw / lanes);
        if (!odd && edge > 0.5 && edge < lanes - 0.5) {
            float d = abs(q - edge), w = fwidth(q);
            col = mix(col, paletteClamp(pal, 0.95), 1 - smoothstep(lineWidth, lineWidth + w, d));
        }
    } else if (part == RUMBLE) {
        col = paletteClamp(pal, odd ? 1.0 : 0.55) * (0.6 + 0.4 * shade);
    } else if (part == GROUND) {
        col = palette(pal, 0.05) * (0.3 + 0.5 * shade);
        float gs = max(p.gridSize, 0.1);
        float g = max(gridLine((in.road.x + fmod(r.T, gs)) / gs, 0.02), gridLine(in.road.y / gs, 0.02));
        col = mix(col, paletteClamp(pal, 0.85) * 1.3, g * p.grid);
    } else if (part == BODY) {
        col = paletteClamp(pal, p.carColor) * (0.2 + 0.9 * shade) + paletteClamp(pal, 1.0) * rim * 0.35;
    } else if (part == STRIPE) {
        col = paletteClamp(pal, p.stripeColor) * (0.7 + 0.5 * shade);
    } else if (part == GLASS) {
        col = mix(palette(pal, 0.04), palette(pal, 0.5), saturate(nrm.y) * 0.6) * 0.7 + paletteClamp(pal, 0.9) * rim * 0.5;
    } else if (part == LIGHT) {
        col = paletteClamp(pal, 1.0) * (0.6 + p.lights);
    } else if (part == WHEEL) {
        col = palette(pal, 0.03) * (0.4 + 0.6 * shade);
    } else if (part == TRUNK) {
        col = palette(pal, 0.08) * (0.3 + 0.7 * shade);
    } else if (part == FROND) {
        col = palette(pal, 0.16) * (0.3 + 0.7 * shade);
    } else if (part == SUN) {
        col = paletteClamp(pal, mix(0.65, 1.0, in.road.y * 0.5 + 0.5)) * 1.2;
        fogAmount = 0;
    } else {
        col = palette(pal, 0.1 + 0.18 * shade) * 0.8;
        fogAmount = 0.4;
    }

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
    // Ahead (-x), or behind (+x) when the camera looks back past the car.
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
    float star = step(0.993, hash21(cell)) * saturate(h * 2 - 0.2);
    star *= 0.5 + 0.5 * sin(f.time * (1 + hash21(cell + 7) * 3) + hash21(cell + 3) * 6.28);
    col += paletteClamp(pal, 1.0) * star * 0.7 * p.bgGlow;
    return float4(col, 0);
}
