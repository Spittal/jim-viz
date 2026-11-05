// Low-poly generator: flat-shaded procedural meshes with displacement, twist,
// shattering, instancing and wireframes. Mesh shape and detail are set in the scene JSON.

// Inputs. Palette colours the faces, wires, fog and background (map a Palette's Colours into
// it); Spectrum pushes vertices out (map Audio In's Spectrum into it).
// @palette pal Palette
// @spectrum spec Spectrum

// Shape
// @param scale 1.2 0.1 4
// @param noiseAmount 0.35 0 2
// @param noiseScale 1.4 0.1 8
// @param noiseSpeed 0.25 0 4
// @param spikes 0 0 3
// @param twist 0 -6 6
// @param explode 0 0 4
// @param stretch 1 0.2 4
// Audio: push vertices out by the Spectrum input. spectrumMode picks how a vertex maps to a frequency:
// 0 = height (bass at the bottom), 1 = random per face, 2 = angle around the center,
// 3 = distance from the center (rings on a plane).
// @param spectrum 0 0 2
// @param spectrumMode 0 0 3 int
// Instances
// @param instances 1 1 96 int
// @param spread 3 0 20
// @param spin 0.2 -4 4
// @param tumble 0.3 0 4
// Look
// @param wire 0 0 1
// @param fill 1 0 1
// @param bands 6 1 16 int
// @param colorShift 0 0 1
// @param colorSpeed 0 -1 1
// @param light 1.1 0 3
// @param fog 0.04 0 0.5
// @param bgGlow 0.5 0 2
// Video inputs: map a video output (a Webcam) into Background to put it behind the mesh, or into
// Texture to paint it onto the faces. videoBg and videoTex are how much of each shows.
// videoMap picks how faces pick up the texture: Faces (every polygon shows the whole video,
// sliced onto it), Screen (as seen from the camera, so the mesh becomes a window onto the
// video), Shards (every face shows its own patch of the screen view), Sphere (wrapped around
// the object), Normal (by face direction, kaleidoscopic) or Front (projected flat from the
// front, the way Depth is, so a webcam's video sits on its own depth relief; best with the
// field shape). videoScatter turns and shifts each face's copy by a random amount in Faces
// mode, so the facets don't all match.
// videoTint recolours the video through the palette by brightness.
// @video bgVideo Background
// @video texVideo Texture
// @param videoBg 1 0 1
// @param videoTex 0.8 0 1
// @param videoMap 0 0 5 int Faces,Screen,Shards,Sphere,Normal,Front
// @param videoScale 1 0.25 4
// @param videoScatter 0 0 1
// @param videoTint 0 0 1
// Depth: map a Webcam's Depth output into Depth to raise the mesh where things are near the
// camera, along each vertex's normal. It's projected flat from the front: the field shape
// (a 16:9 sheet) lines up with it exactly. depth is how far near things rise; depthCut hides
// faces stretched across a depth edge, so a person stands free of the wall behind instead
// of being joined to it by a skirt.
// @video depthVideo Depth
// @param depth 2 0 6
// @param depthCut 0.5 0 1

// The field shape's size; matches MeshShape.fieldSize.
constant float FIELD_W = 6.4;
constant float FIELD_H = 3.6;

// Where a mesh point lands in a front-projected video: the field shape covers it exactly.
inline float2 frontUV(float3 pos) { return float2(0.5 - pos.z / FIELD_W, 0.5 - pos.y / FIELD_H); }

struct MeshVertex {
    float4 position;     // w = per-face random
    float4 faceNormal;
    float4 smoothNormal;
    float4 bary;
};

struct Camera {
    float4x4 viewProj;
    float4 position;
};

// The video input at uv, optionally recoloured through the palette.
inline float3 videoColor(texture2d<float> vid, texture2d<float> pal, float2 uv, float tint) {
    float3 v = vid.sample(linearRepeat, uv).rgb;
    return mix(v, palette(pal, luma(v) * 0.9 + 0.05) * (0.4 + luma(v)), tint);
}

struct GenOut {
    float4 position [[position]];
    float3 world;
    float3 bary;
    float faceRand [[flat]];
    float inst [[flat]];
    // The mesh point moved by depth only, its face's normal and front-projected uv, for
    // depthCut and the Front video mode.
    float3 depthPos;
    float3 faceN [[flat]];
    float2 frontUV;
};

vertex GenOut gen_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device MeshVertex* verts [[buffer(0)]],
                         constant Frame& f [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant Camera& cam [[buffer(3)]],
                         texture2d<float> spec [[texture(1)]],
                         texture2d<float> depthVid [[texture(4)]]) {
    MeshVertex v = verts[vid];
    float ir = hash11(float(iid) * 17.13 + 1.7);
    float t = f.time * p.noiseSpeed;
    float3 pos = v.position.xyz;
    float2 fuv = frontUV(pos);

    // Depth: near things (white) rise toward the camera.
    if (hasInput(f, 4) && p.depth > 0) {
        float d = luma(depthVid.sample(linearClamp, fuv, level(0)).rgb);
        pos += v.smoothNormal.xyz * d * p.depth;
    }
    float3 depthPos = pos;

    // Displace along the smooth normal so neighbouring faces stay joined.
    float3 np = pos * p.noiseScale + float3(0, t, ir * 13.0);
    float n = fbm3(np);
    float sp = pow(abs(noise3(np * 2.7 + 5.0)), 6.0) * p.spikes * 4.0;
    float u;
    if (p.spectrumMode < 0.5)      u = saturate(v.position.y * 0.5 + 0.5);
    else if (p.spectrumMode < 1.5) u = v.position.w;
    else if (p.spectrumMode < 2.5) u = abs(atan2(v.position.z, v.position.x)) / M_PI_F;
    else                           u = saturate(length(v.position.xz) / 5.0);
    float sv = p.spectrum > 0 ? spectrum(spec, u * 0.85) : 0;
    pos += v.smoothNormal.xyz * (n * p.noiseAmount + sp + sv * p.spectrum);

    pos.y *= p.stretch;
    pos.xz = rot2(pos.y * p.twist) * pos.xz;

    // Shatter: push each face out along its own normal.
    pos += v.faceNormal.xyz * p.explode * (0.3 + v.position.w);
    pos *= p.scale;

    // Each instance tumbles on its own random axis.
    float3 axis = normalize(float3(hash11(ir * 3.1) - 0.5, hash11(ir * 5.7) - 0.5, hash11(ir * 7.3) - 0.5) + 1e-3);
    pos = rotAxis(axis, f.time * p.tumble * (0.5 + ir)) * pos;

    // Instances sit on a Fibonacci sphere.
    float count = max(p.instances, 1.0);
    if (count > 1.5) {
        float i = float(iid);
        float y = 1 - 2 * (i + 0.5) / count;
        float r = sqrt(max(1 - y * y, 0.0));
        float phi = i * 2.39996323;
        pos += float3(cos(phi) * r, y, sin(phi) * r) * p.spread;
    }

    // Global spin around the vertical axis.
    pos.xz = rot2(f.time * p.spin) * pos.xz;

    GenOut o;
    o.world = pos;
    o.position = cam.viewProj * float4(pos, 1);
    o.bary = v.bary.xyz;
    o.faceRand = v.position.w;
    o.inst = ir;
    o.depthPos = depthPos;
    o.faceN = v.faceNormal.xyz;
    o.frontUV = fuv;
    return o;
}

fragment float4 gen_fragment(GenOut in [[stage_in]],
                             texture2d<float> pal [[texture(0)]],
                             texture2d<float> vid [[texture(3)]],
                             constant Frame& f [[buffer(0)]],
                             constant Params& p [[buffer(1)]],
                             constant Camera& cam [[buffer(2)]]) {
    // Depth edges: a face the depth stood up on its side spans a jump (a person's outline
    // against the wall), so drop it. Compares the face as moved by depth with how it was.
    if (p.depthCut > 0 && hasInput(f, 4)) {
        float3 dn = cross(dfdy(in.depthPos), dfdx(in.depthPos));
        if (abs(dot(normalize(dn), in.faceN)) < p.depthCut * 0.7) discard_fragment();
    }

    // Flat normal from screen-space derivatives: the low-poly look.
    float3 nrm = normalize(cross(dfdy(in.world), dfdx(in.world)));
    float3 V = normalize(cam.position.xyz - in.world);
    if (dot(nrm, V) < 0) nrm = -nrm;

    float3 L = normalize(float3(sin(f.time * 0.3), 0.8, cos(f.time * 0.3)));
    float diff = max(dot(nrm, L), 0.0) * p.light;
    float rim = pow(1 - saturate(dot(nrm, V)), 3.0);

    float shade = saturate(diff * 0.65 + in.faceRand * 0.2 + rim * 0.35);
    float bands = max(p.bands, 1.0);
    shade = floor(shade * bands) / bands;
    float t = 0.15 + 0.85 * shade + p.colorShift + f.time * p.colorSpeed + in.inst * 0.1;
    float3 col = palette(pal, t) * p.fill;

    if (hasInput(f, 3) && p.videoTex > 0) {
        float2 uv;
        int mode = int(p.videoMap + 0.5);
        float2 screen = in.position.xy / f.resolution;
        if (mode == 0) {
            // The triangle's corners pin the video's bottom-left, bottom-right and top-centre,
            // so each polygon shows the whole frame, squeezed into its own shape.
            float2 tri = in.bary.x * float2(0, 1) + in.bary.y * float2(1, 1) + in.bary.z * float2(0.5, 0);
            float2 c = (tri - 0.5) / p.videoScale;
            float r1 = in.faceRand, r2 = hash11(in.faceRand * 53.1 + in.inst * 7.0);
            c = rot2((r1 - 0.5) * 2 * M_PI_F * p.videoScatter) * c;
            uv = c + 0.5 + (float2(r1, r2) - 0.5) * p.videoScatter * 0.6;
        } else if (mode == 1) {
            uv = (screen - 0.5) / p.videoScale + 0.5;
        } else if (mode == 2) {
            float2 off = float2(in.faceRand, hash11(in.faceRand * 91.7 + in.inst)) * 7.0;
            uv = (screen - 0.5) / p.videoScale + 0.5 + off;
        } else if (mode == 3) {
            float3 d = normalize(in.world);
            uv = float2(atan2(d.z, d.x) / (2 * M_PI_F) + 0.5, acos(clamp(d.y, -1.0, 1.0)) / M_PI_F) * p.videoScale;
        } else if (mode == 4) {
            uv = nrm.xy * 0.5 * p.videoScale + 0.5;
        } else {
            uv = (in.frontUV - 0.5) / p.videoScale + 0.5;
        }
        float3 v = videoColor(vid, pal, uv, p.videoTint) * (0.35 + 0.85 * shade);
        col = mix(col, v * max(p.fill, 0.35), p.videoTex);
    }

    // Wireframe from barycentrics.
    float e = min(min(in.bary.x, in.bary.y), in.bary.z);
    float w = 1 - smoothstep(0.0, fwidth(e) * 1.5, e);
    float3 wireColor = paletteClamp(pal, 1.0) * 1.4;
    col = mix(col, wireColor, w * p.wire);
    if (p.fill < 0.01 && w * p.wire < 0.05) discard_fragment();

    // Fog toward the background color.
    float dist = length(cam.position.xyz - in.world);
    float3 bg = paletteClamp(pal, 0.0) * p.bgGlow * 0.35;
    col = mix(col, bg, 1 - exp(-dist * p.fog));

    return float4(col, 1);
}

// Drawn behind the mesh. Alpha 0 marks background so feedback can trail behind geometry.
fragment float4 gen_background(FXOut in [[stage_in]],
                               texture2d<float> pal [[texture(0)]],
                               texture2d<float> vid [[texture(2)]],
                               constant Frame& f [[buffer(0)]],
                               constant Params& p [[buffer(1)]]) {
    float2 c = in.uv - 0.5;
    c.x *= f.resolution.x / f.resolution.y;
    float g = saturate(1 - length(c) * 1.1);
    float n = fbm3(float3(c * 2.5, f.time * 0.05));
    float3 col = paletteClamp(pal, 0.04 + 0.12 * (n * 0.5 + 0.5)) * p.bgGlow * (0.15 + 0.6 * g * g);
    if (hasInput(f, 2) && p.videoBg > 0) {
        col = mix(col, videoColor(vid, pal, in.uv, p.videoTint), p.videoBg);
    }
    return float4(col, 0);
}
