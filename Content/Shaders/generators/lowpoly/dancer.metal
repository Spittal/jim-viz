// Dancer: a low-poly figure of faceted bones, each a `sides`-sided shard, dancing real
// motion-capture performances. model picks the body: Male (lean and faceless), Female (slighter,
// with a ponytail that swings) or Shrek (a stocky ogre with trumpet ears). style picks the dance,
// one of AIST++'s ten genres: about 21 choreographed performances of 30-50 seconds each
// (Content/Motion, baked by scripts/bake-motion.py), danced one after another, each picked to
// open near the pose the last left off in and handed over to on a bar line.
// Posed on the CPU by DanceSim (Render/DanceSim.swift): a clip turns the 22 joints of the body's
// skeleton (hips, a three-part spine, neck, head, collars, arms, hands, legs, feet, toes), and
// the body brings its own proportions.
//
// tempo is the dance's speed: 1 is 120 BPM. Map Audio In · Sync into Sync and it follows
// the beat instead: 1 is on the beat, 2 double time, 0.5 half time. The clips are picked for a
// tempo near the music's and stretched to land on its beats. nudge moves the dance against the
// beat, in beats: later above 0, earlier below. travel is how far the dancer moves
// over the floor (0 dances on the spot). jiggle wobbles the belly as the hips bounce.
//
// limbWidth thickens every bone, limbLength stretches the arms and legs, belly fattens the body,
// headSize scales the head (and its ears, nose and hair), earSize Shrek's ears alone, hair the
// ponytail's length. It takes its colours from the Palette like every geo (map a green one in for
// an ogre); clothes shifts the clothes (body and legs) along the palette, and clothesDark darkens them.
// @mesh dancer
// @clock sync Sync
// @group Shape
// @param model 0 0 2 int Male,Female,Shrek mesh
// @param sides 5 3 12 int mesh
// @param limbWidth 1 0 3
// @param limbLength 1 0 2
// @param belly 1 0 3
// @param headSize 1 0 3
// @param earSize 1 0 4
// @param hair 1 0 3
// @param clothes 0 0 1
// @param clothesDark 0 0 1
// @param scale 1 0 4
// @group Dance
// @param style 0 0 9 int Hip_Hop,LA_Hip_Hop,House,Popping,Locking,Waacking,Krump,Break,Street_Jazz,Ballet_Jazz
// @param tempo 1 0 4 rate
// @param nudge 0 -0.5 0.5
// @param travel 1 0 2
// @param jiggle 0 0 1

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Limb (each bone its own band, bass in the hips), Along (bass where a bone starts, highs at
// its end) or Random (per face).
// @group Spectrum spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Limb,Along,Random

// @include _shared.metal

constant int boneCount = 27;

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         const device float4* sim [[buffer(4)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int bone = int(v.shape.x + 0.5);

    // The bone as DanceSim posed it: (start, length), (direction, width), (sideways, clothed).
    float4 a = sim[bone * 3], b = sim[bone * 3 + 1], c = sim[bone * 3 + 2];
    float3 dir = b.xyz;
    float3 S1 = c.xyz - dot(c.xyz, dir) * dir;
    S1 = length(S1) > 1e-3 ? normalize(S1) : normalize(cross(dir, float3(0.3, 1, 0.2)));
    float3 S2 = cross(dir, S1);

    float3 off = (v.shape.z * S1 + v.shape.w * S2) * b.w;
    float3 pos = a.xyz + dir * v.shape.y * a.w + off;
    float3 n = length(off) > 1e-5 ? normalize(off) : dir * sign(v.shape.y - 0.5);
    float3 lf = v.faceNormal.xyz;
    float3 fn = lf.x * dir + lf.y * S1 + lf.z * S2;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? (float(bone) + 0.5) / boneCount : mode == 1 ? 0.2 + saturate(v.shape.y) * 0.8 : v.position.w;
    GeoPoint g = geoPoint(pos, n, fn, u);
    if (c.w > 0.5) {
        g.tone = p.clothes;
        g.dark = p.clothesDark;
    }
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
