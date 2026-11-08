// Globe: the world, its countries the faces of a sphere (Natural Earth, Content/Maps/world.json;
// no labels). detail picks how closely the countries follow their real borders, from Crude
// (a country is a handful of corners, small islands gone) to Fine. Each country is one face:
// it is lit as one flat piece, wire draws its outline and explode lifts it whole. The ocean is a plain low-poly sphere under
// them: facets subdivides it like the Sphere's detail, ocean is its radius (the countries sit
// at 1; 0 hides it, leaving a hollow shell of countries). landShade moves the countries along
// the palette, away from the ocean's colours; variety spreads each country's colour from its
// neighbours'.
// @mesh globe
// @group Shape
// @param detail 3 0 5 int Crude,Coarse,Low,Medium,High,Fine mesh
// @param facets 3 0 5 int mesh
// @param ocean 0.97 0 1.2
// @param landShade 0.35 0 1
// @param variety 0.25 0 1
// @param scale 1 0 4

// Audio: Spectrum pushes vertices out. spectrumMode picks the frequency each vertex reads:
// Longitude (around the globe), Latitude (bass at the south pole) or Country (each country
// its own band, and each ocean face).
// @group Audio spec
// @param spectrum 0 0 2
// @param spectrumMode 0 0 2 int Longitude,Latitude,Country

// @include _shared.metal

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]]) {
    MeshVertex v = verts[vid];
    float3 n = v.smoothNormal.xyz;
    bool land = v.shape.w > 0.5;

    int mode = int(p.spectrumMode + 0.5);
    float u = mode == 0 ? atan2(-n.z, n.x) / (2 * M_PI_F) + 0.5
            : mode == 1 ? asin(clamp(n.y, -1.0, 1.0)) / M_PI_F + 0.5
            : v.position.w;
    GeoPoint g = geoPoint(land ? n : n * p.ocean, n, v.faceNormal.xyz, u);
    g.tone = land ? p.landShade + (v.position.w - 0.5) * p.variety : 0;
    g.faceLit = land ? 1 : 0;
    return lowpolyVertex(g, v, iid, f, p, cam, spec);
}
