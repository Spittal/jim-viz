// Instruments: a jazz band with nobody playing it. A drum kit in the middle, a saxophone on
// its left, a trombone on its right and a trumpet over the top. Tubes are `sides`-sided and
// drums and cymbals twice that. drums, sax, trumpet and trombone size each one (0 and it's not
// there); spacing moves the horns away from the kit; variety spreads the four along the palette.
// @mesh instruments
// @group Shape
// @param sides 6 3 12 int mesh
// @param drums 1 0 3
// @param sax 1 0 3
// @param trumpet 1 0 3
// @param trombone 1 0 3
// @param spacing 1 0 4
// @param variety 0.2 0 1
// @param scale 1 0 4

// Play: what a player would do, each a knob to map a hit, an LFO or a MIDI control onto.
// kick, snare and toms swell their drums and pop the heads; hat lifts the hi-hat's top cymbal;
// cymbals rocks the crash and the ride on their stands. blow flares the three horns' bells;
// fingers works the trumpet's valves and the saxophone's keys, each at its own pace, all up
// again at 0 and 1; slide runs the trombone's slide out. swing sways the horns and
// swingSpeed is how fast.
// @group Play
// @param kick 0 0 1
// @param snare 0 0 1
// @param toms 0 0 1
// @param hat 0 0 1
// @param cymbals 0 0 1
// @param blow 0 0 1
// @param fingers 0 0 1
// @param slide 0 0 1
// @param swing 0 0 1
// @param swingSpeed 1 0 4 rate

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Instrument (the kit the bass, then the trombone, the saxophone and the trumpet the highs),
// Along (each horn from its mouthpiece to its bell, the kit from its kick to its cymbals) or
// Random (per face). honk flares each horn's bell by its own band.
// @group Spectrum spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Instrument,Along,Random
// @param honk 0 0 1

// @include _shared.metal

// How a face moves. Must match InstrumentMove in Render/InstrumentsMesh.swift.
constant int MOVE_KICK = 1, MOVE_SNARE = 2, MOVE_TOM = 3, MOVE_HAT = 4, MOVE_CYMBAL = 5,
             MOVE_BELL = 6, MOVE_KEY = 7, MOVE_SLIDE = 8;

// Where the crash and the ride sit on their stands. Must match MeshBuilder.cymbalPivots in
// Render/InstrumentsMesh.swift.
constant float3 cymbalPivot[2] = { float3(-0.3, 0.72, -0.62), float3(-0.2, 0.5, 0.98) };

// Drums, saxophone, trumpet, trombone: where each sits (the horns at spacing 1), which way its
// own +x points and which way is up for it, and its band of the spectrum. The front is +x and
// the left of the picture +z.
constant float3 bandPlace[4] = { float3(0, 0, 0), float3(0.2, 0.05, 2.1), float3(0.3, 1.55, -0.1), float3(0.4, -0.05, -2.3) };
constant float3 bandAhead[4] = { float3(1, 0, 0), float3(0.35, 0, -0.94), float3(0.55, 0.12, 0.83), float3(0.5, 0.45, 0.74) };
constant float3 bandUp[4] = { float3(0, 1, 0), float3(0, 1, 0.14), float3(0, 1, 0), float3(0, 1, 0) };
constant float bandSpectrum[4] = { 0.05, 0.55, 0.85, 0.3 };

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    int code = int(v.shape.x + 0.5);
    int which = code % 10, move = code / 10;
    float weight = v.shape.z, index = v.shape.w;
    float3 pos = v.position.xyz, n = v.smoothNormal.xyz, fn = v.faceNormal.xyz;

    // Played, in the instrument's own space.
    if (move == MOVE_KICK || move == MOVE_SNARE || move == MOVE_TOM) {
        float hit = move == MOVE_KICK ? p.kick : move == MOVE_SNARE ? p.snare : p.toms;
        pos += n * hit * mix(0.05, 0.25, weight);
    } else if (move == MOVE_HAT) {
        pos.y += p.hat * 0.14;
    } else if (move == MOVE_CYMBAL) {
        int i = int(index + 0.5);
        float3x3 rock = rotAxis(float3(1, 0, 0), p.cymbals * (i == 0 ? 0.5 : -0.5));
        pos = cymbalPivot[i] + rock * (pos - cymbalPivot[i]);
        n = rock * n;
        fn = rock * fn;
    } else if (move == MOVE_BELL) {
        float honk = p.honk > 0 ? spectrum(spec, bandSpectrum[which]) * p.honk : 0;
        pos += n * weight * (p.blow + honk) * 0.3;
    } else if (move == MOVE_KEY) {
        float press = 0.5 - 0.5 * cos(p.fingers * 2 * M_PI_F * (1 + fmod(index, 3.0)));
        pos -= n * press * weight;
    } else if (move == MOVE_SLIDE) {
        pos.x += p.slide * 0.75 * weight;
    }

    // Sized, turned and put in its place. The horns sway, each in its own time.
    float size = which == 0 ? p.drums : which == 1 ? p.sax : which == 2 ? p.trumpet : p.trombone;
    float3 ahead = normalize(bandAhead[which]);
    float3 side = normalize(cross(ahead, bandUp[which]));
    float3x3 m = float3x3(ahead, cross(side, ahead), side);
    float3 place = bandPlace[which] * (which == 0 ? 1.0 : p.spacing);
    if (which > 0 && p.swing > 0) {
        float t = p.swingSpeedPhase * 3 + which * 2.1;
        m = rotAxis(float3(1, 0, 0), sin(t) * p.swing * 0.35) * rotAxis(float3(0, 0, 1), cos(t * 0.7) * p.swing * 0.2) * m;
        place.y += sin(t * 1.3) * p.swing * 0.15;
    }
    pos = m * (pos * size) + place;
    n = m * n;
    fn = m * fn;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? bandSpectrum[which] : mode == 1 ? v.shape.y : v.position.w;
    GeoPoint g = geoPoint(pos, n, fn, u);
    g.tone = which * 0.25 * p.variety;
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
