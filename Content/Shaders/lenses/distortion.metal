// Lens Distortion: the lens model a grid solve estimates, with Nuke's LensDistortion knobs,
// written out as an ST map (Lens · ST Map). Map that into the Camera's Lens input and the
// rendered picture is reprojected through it, before the effects.
//
// The model takes an undistorted point u (centred on the distortion centre, y up, 1 at the
// frame's corners) to where the lens puts it:
//   D(u) = u + d,  d = u (k1 r² + k2 r⁴) + (asymX u.x u.y², asymY u.y u.x²),  d.x × squeeze
// Negative k1 is barrel (straight lines bow out, like the grid through a wide lens), positive
// is pincushion. k2 bends the edges harder than the middle.
//
// direction Distort: makes the clean render look shot through the lens. Each output pixel
// reads from D⁻¹ of where it is, solved by Newton's method; where the lens folds over (very
// strong barrel) there's no answer and the pixel is black.
// direction Undistort: the inverse, flattening a lensy picture. Each pixel reads from D(u).
// scale zooms the result, to push black edges out of frame.
//
// @param k1 -0.15 -1 1
// @param k2 0 -1 1
// @param centerX 0 -0.5 0.5
// @param centerY 0 -0.5 0.5
// @param squeeze 1 0.5 2
// @param asymX 0 -1 1
// @param asymY 0 -1 1
// @param scale 1 0.25 4
// @param direction 0 0 1 int Distort,Undistort
// centerX, centerY: the distortion centre's offset from the frame centre, in frames (y up).
// squeeze: the anamorphic squeeze; scales the distortion across, not the picture.

inline float2 lensDistort(float2 u, constant Params& p) {
    float r2 = dot(u, u);
    float2 d = u * (p.k1 * r2 + p.k2 * r2 * r2) + float2(p.asymX * u.x * u.y * u.y, p.asymY * u.y * u.x * u.x);
    d.x *= p.squeeze;
    return u + d;
}

// Writes s, t (Nuke's ST map: t runs bottom to top) into red and green.
fragment float4 lens(FXOut in [[stage_in]],
                     constant Frame& f [[buffer(0)]],
                     constant Params& p [[buffer(1)]]) {
    float2 res = f.resolution;
    float halfDiag = 0.5 * length(res);
    float2 centre = (float2(0.5 + p.centerX, 0.5 - p.centerY)) * res;
    // Output point, in the model's units.
    float2 q = (in.uv * res - centre) / halfDiag;
    q.y = -q.y;
    q /= p.scale;

    float2 u;
    if (p.direction < 0.5) {
        // Newton on D(u) = q, from u = q.
        u = q;
        const float h = 1e-3;
        for (int i = 0; i < 8; i++) {
            float2 fu = lensDistort(u, p) - q;
            float2 jx = (lensDistort(u + float2(h, 0), p) - lensDistort(u - float2(h, 0), p)) / (2 * h);
            float2 jy = (lensDistort(u + float2(0, h), p) - lensDistort(u - float2(0, h), p)) / (2 * h);
            float det = jx.x * jy.y - jy.x * jx.y;
            if (abs(det) < 1e-6) break;
            u -= float2(jy.y * fu.x - jy.x * fu.y, -jx.y * fu.x + jx.x * fu.y) / det;
        }
        // No inverse here (the lens folds over): read from outside the frame, which is black.
        if (!all(isfinite(u)) || length(lensDistort(u, p) - q) > 1e-3) return float4(-1, -1, 0, 1);
    } else {
        u = lensDistort(q, p);
    }

    u.y = -u.y;
    float2 uv = (u * halfDiag + centre) / res;
    return float4(uv.x, 1 - uv.y, 0, 1);
}
