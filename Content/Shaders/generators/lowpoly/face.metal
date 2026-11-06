// Face: a planar head on a neck, a few dozen flat planes like an artist's planes-of-the-head
// study, with a mouth that sings. It looks toward the front (+x). detail cuts every plane
// finer for the Surface knobs to bend (0 leaves the bare planes). open drops the jaw and parts
// the lips (map Audio In's Harmonic or Level here); jaw is how much of that is the jaw dropping
// rather than just the lips parting. vowel shapes the mouth: -1 a rounded, pushed-out "oo",
// 0 an "ah", 1 a wide "ee". mouthDark darkens the inside of the mouth.
// @mesh face
// @group Shape
// @param detail 0 0 4 int mesh
// @param open 0 0 1
// @param jaw 0.8 0 1
// @param vowel 0 -1 1
// @param mouthDark 0.85 0 1

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Height (bass at the neck), Around (bass at the front) or Random (per plane).
// sing opens the mouth by how loud the voice range of the Spectrum is, on top of open; singVowel
// shapes it by the spectrum's brightness, on top of vowel (brighter is wider, darker rounder).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Height,Around,Random
// @param sing 1 0 3
// @param singVowel 1 0 2

// @include _shared.metal

// Where the jaw hinges, in front of the ear (x, y). The points are MeshBuilder.headPoints in
// Render/FaceMesh.swift.
constant float2 jawHinge = float2(-0.02, -0.02);

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float jawW = v.shape.x, lip = v.shape.y, mouth = v.shape.z;
    float3 pos = v.position.xyz, n = v.smoothNormal.xyz, fn = v.faceNormal.xyz;

    // How open and which vowel: the knobs, plus what the Spectrum's voice range sings.
    float open = p.open, vowel = p.vowel;
    if (p.sing > 0 || p.singVowel > 0) {
        float lo = 0, hi = 0, all = 0;
        for (int i = 0; i < 4; i++) {
            float l = spectrum(spec, 0.36 + i * 0.04), h = spectrum(spec, 0.60 + i * 0.04);
            lo += l;
            hi += h;
            all += l + h + spectrum(spec, 0.26 + i * 0.025);
        }
        open += p.sing * all / 12 * 1.5;
        vowel += p.singVowel * (hi - lo) / (hi + lo + 0.05) * 1.5;
    }
    open = saturate(open);
    vowel = clamp(vowel, -1.0, 1.0);
    float wide = max(vowel, 0.0), round = max(-vowel, 0.0);
    float lips = open * (1 - 0.3 * wide);

    // The lips part: the upper lifts a little, the lower drops by what the jaw doesn't.
    pos.y += lip > 0 ? lips * 0.04 * lip : lips * (1 - p.jaw) * 0.2 * lip;
    // The vowel: the corners stretched wide for "ee", pulled in and the lips pushed out for "oo".
    pos.z *= 1 + (0.3 * wide - 0.35 * round) * mouth;
    pos.x += round * 0.07 * mouth;

    // The jaw swings down about its hinge.
    float th = lips * p.jaw * 0.42 * jawW, c = cos(th), s = sin(th);
    float2x2 r = float2x2(float2(c, -s), float2(s, c));
    pos.xy = r * (pos.xy - jawHinge) + jawHinge;
    n.xy = r * n.xy;
    fn.xy = r * fn.xy;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? saturate(pos.y / 2.4 + 0.5) : mode == 1 ? abs(atan2(pos.z, pos.x)) / M_PI_F : v.position.w;
    GeoPoint g = geoPoint(pos, n, fn, u);
    g.dark = v.shape.w * p.mouthDark;
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
