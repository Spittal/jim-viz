// Water Wheel: `blades` flat paddles hinged along one edge to an invisible axle (the x axis)
// of the given radius, each `segments` × `segments` cells so they can bend. turn spins the
// wheel round its axle. length and width size the paddles. pitch tilts every paddle on its
// hinge (degrees; map a kick here to flap them all at once); curl bends them along their
// length like turbine blades; flutter wobbles each one on its own.
// @mesh wheel
// @group Shape
// @param blades 12 1 48 int mesh
// @param segments 3 1 12 int mesh
// @param radius 0.6 0 3
// @param length 1.4 0.05 4
// @param width 1.5 0.05 6
// @param turn 0.4 -6 6
// @param pitch 0 -90 90
// @param curl 0 -3 3
// @param flutter 0 0 1

// Audio: Spectrum pushes vertices off the paddles. spectrumMode picks the frequency each vertex
// reads: Blade (each paddle its own band), Along (bass at the hinge) or Random (per face).
// flap swings each paddle on its hinge by its own band, up to that many degrees.
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Blade,Along,Random
// @param flap 30 0 90

// @include _shared.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float blade = v.shape.x, t = v.shape.y, s = v.shape.z;
    float a = blade * 2 * M_PI_F + f.time * p.turn;
    float3 radial = float3(0, cos(a), sin(a)), tang = float3(0, -sin(a), cos(a));

    // The paddle's angle at its hinge: pitch, its own band's flap and its own wobble.
    float br = hash11(blade * 113.7 + 3.1);
    float flap = p.flap > 0 ? spectrum(spec, blade * 0.85) * p.flap : 0;
    float wobble = noise3(float3(br * 37.0, f.time * 1.7, 0)) * p.flutter * 60.0;
    float hinge = (p.pitch + flap + wobble) * M_PI_F / 180;

    // Along a paddle bent into an arc by curl: the chord from the hinge to the point t along.
    float k = p.curl * t * 0.5;
    float chord = t * p.length * (abs(k) > 1e-3 ? sin(k) / k : 1.0);
    float ang = hinge + k;
    float3 pos = float3(s * p.width, 0, 0) + radial * p.radius + (radial * cos(ang) + tang * sin(ang)) * chord;

    // The paddle's normal here (displacement) and at the face's centre (explode).
    float an = hinge + p.curl * t, ac = hinge + p.curl * v.shape.w;
    float3 dn = radial * cos(an) + tang * sin(an), dc = radial * cos(ac) + tang * sin(ac);
    float3 n = float3(0, -dn.z, dn.y), fn = float3(0, -dc.z, dc.y);

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? blade : mode == 1 ? t : v.position.w;
    return lowpolyVertex(geoPoint(pos, n, fn, u), v, iid, f, p, cam, spec);
}
