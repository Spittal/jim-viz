import simd

/// Face: a planar head on a neck, a few dozen flat planes like an artist's planes-of-the-head
/// study, looking toward +x with +y up. The shader hinges the jaw and shapes the lips.
extension MeshBuilder {
    /// The right half's points (z ≥ 0), six numbers each: x, y, z, then how much the point goes
    /// with the jaw (0...1), how it parts with the lips (above 0 it lifts with the upper lip,
    /// below 0 it drops with the lower) and how much the vowel moves it (the lips and the
    /// mouth's corners). The last four are the back of the mouth.
    /// The jaw's hinge is `jawHinge` in Shaders/generators/lowpoly/face.metal.
    static let headPoints: [Float] = [
        -0.109, 1.191, 0, 0, 0, 0,  0.379, 1.058, 0, 0, 0, 0,  0.701, 0.684, 0, 0, 0, 0,
        0.755, 0.445, 0, 0, 0, 0,  0.718, 0.319, 0, 0, 0, 0,  1, -0.07, 0, 0, 0, 0,
        0.78, -0.2, 0, 0, 0, 0,  0.88, -0.3, 0, 0, 0, 0.5,  0.8, -0.395, 0, 0, 1, 1,
        0.8, -0.395, 0, 1, -1, 1,  0.83, -0.51, 0, 1, -0.4, 0.6,  0.75, -0.6, 0, 1, 0, 0,
        0.82, -0.7, 0, 1, 0, 0,  0.78, -0.88, 0, 1, 0, 0,  0.274, -0.836, 0, 0.5, 0, 0,
        0.208, -1.142, 0, 0, 0, 0,  -0.657, 1.005, 0, 0, 0, 0,  -0.879, 0.435, 0, 0, 0, 0,
        -0.742, -0.156, 0, 0, 0, 0,  -0.541, -0.493, 0, 0, 0, 0,  -0.666, -1.059, 0, 0, 0, 0,
        -0.122, 1.125, 0.463, 0, 0, 0,  0.322, 1.009, 0.407, 0, 0, 0,  0.553, 0.689, 0.559, 0, 0, 0,
        0.613, 0.426, 0.531, 0, 0, 0,  0.104, 0.612, 0.758, 0, 0, 0,  -0.267, 0.882, 0.687, 0, 0, 0,
        -0.644, 0.491, 0.651, 0, 0, 0,  -0.523, 0.995, 0.436, 0, 0, 0,  -0.527, -0.101, 0.594, 0, 0, 0,
        0.721, 0.418, 0.159, 0, 0, 0,  0.622, 0.304, 0.141, 0, 0, 0,  0.426, 0.249, 0.609, 0, 0, 0,
        0.682, 0.004, 0.255, 0, 0, 0,  0.495, 0.044, 0.595, 0, 0, 0,  0.056, 0.154, 0.777, 0, 0, 0,
        0.698, 0.304, 0.106, 0, 0, 0,  0.97, -0.07, 0.09, 0, 0, 0,  0.74, -0.17, 0.19, 0, 0, 0,
        0.82, -0.29, 0.134, 0, 0, 0.6,  0.77, -0.395, 0.168, 0, 0.8, 1,  0.77, -0.395, 0.168, 1, -0.8, 1,
        0.68, -0.4, 0.314, 0.5, 0, 1,  0.785, -0.5, 0.157, 1, -0.3, 0.6,  0.694, -0.596, 0.174, 1, 0, 0,
        0.73, -0.7, 0.28, 1, 0, 0,  0.69, -0.88, 0.28, 1, 0, 0,  0.333, -0.713, 0.497, 1, 0, 0,
        -0.033, -0.42, 0.679, 1, 0, 0,  0.125, -0.828, 0.337, 0.3, 0, 0,  -0.292, -0.587, 0.454, 0, 0, 0,
        0.053, -1.139, 0.352, 0, 0, 0,  -0.395, -1.101, 0.473, 0, 0, 0,  0.38, -0.34, 0, 0, 0, 0,
        0.38, -0.46, 0, 1, 0, 0,  0.4, -0.35, 0.269, 0, 0, 0,  0.4, -0.45, 0.269, 1, 0, 0,
    ]
    /// The right half's planes, each wound counter-clockwise seen from outside. The left half
    /// mirrors them.
    static let headPlanes: [[Int]] = [
        [21, 22, 1, 0], [16, 28, 21, 0], [22, 23, 2, 1], [23, 24, 30, 3, 2], [25, 23, 22], [21, 26, 25, 22],
        [28, 26, 21], [27, 26, 28], [17, 27, 28, 16], [18, 29, 27, 17], [26, 27, 35, 25], [27, 29, 48, 35],
        [29, 50, 48], [18, 19, 50, 29], [23, 25, 35, 24], [35, 34, 32, 24], [3, 30, 36, 4], [30, 31, 36],
        [4, 36, 37, 5], [36, 31, 38, 37], [5, 37, 38, 6], [31, 33, 38], [30, 24, 32, 31], [31, 32, 34, 33],
        [6, 38, 39, 7], [38, 42, 39], [7, 39, 40, 8], [39, 42, 40], [9, 41, 43, 10], [41, 42, 43],
        [10, 43, 44, 11], [11, 44, 45, 12], [12, 45, 46, 13], [43, 42, 44], [42, 45, 44], [33, 34, 42, 38],
        [34, 47, 42], [42, 47, 45], [45, 47, 46], [34, 35, 48, 47], [13, 46, 49, 14], [46, 47, 49],
        [47, 48, 50, 49], [14, 49, 51, 15], [49, 50, 52, 51], [50, 19, 20, 52], [15, 51, 52, 20], [8, 40, 55, 53],
        [40, 42, 55], [54, 56, 41, 9], [56, 42, 41], [53, 55, 56, 54], [56, 55, 42],
    ]

    /// A plane's triangles share one face random and one normal, so it shades and explodes as
    /// one piece, and the wireframe draws only its outline. `detail` cuts every triangle in
    /// four that many times, for the surface knobs to bend.
    /// shape: x = how much the vertex goes with the jaw, y = how it parts with the lips,
    /// z = how much the vowel moves it, w = 1 on the planes inside the mouth.
    mutating func face(detail: Int) {
        struct Corner { var p: SIMD3<Float>, n: SIMD3<Float>, s: SIMD4<Float> }
        let raw = MeshBuilder.headPoints
        var pos: [SIMD3<Float>] = [], weights: [SIMD3<Float>] = []
        for i in stride(from: 0, to: raw.count, by: 6) {
            pos.append([raw[i], raw[i + 1], raw[i + 2]])
            weights.append([raw[i + 3], raw[i + 4], raw[i + 5]])
        }
        let half = pos.count, firstInside = half - 4
        // Points off the centre line get a mirror image.
        var mirror = Array(0..<half)
        for i in 0..<half where pos[i].z != 0 {
            mirror[i] = pos.count
            pos.append(pos[i] * [1, 1, -1])
            weights.append(weights[i])
        }
        var planeRand = SplitMix(seed: 0xFACE)
        var planes: [(corners: [Int], rand: Float, inside: Float)] = []
        var normals = [SIMD3<Float>](repeating: .zero, count: pos.count)
        for plane in MeshBuilder.headPlanes {
            let rand = planeRand.nextFloat()
            let inside: Float = plane.contains { $0 >= firstInside } ? 1 : 0
            for corners in [plane, plane.reversed().map { mirror[$0] }] {
                // Newell's normal: the polygon's area along each axis.
                var n = SIMD3<Float>.zero
                for (k, i) in corners.enumerated() { n += simd_cross(pos[i], pos[corners[(k + 1) % corners.count]]) }
                for i in corners { normals[i] += n }
                planes.append((corners, rand, inside))
            }
        }
        normals = normals.map { simd_normalize($0) }

        func mid(_ u: Corner, _ v: Corner) -> Corner {
            Corner(p: (u.p + v.p) / 2, n: simd_normalize(u.n + v.n), s: (u.s + v.s) / 2)
        }
        for plane in planes {
            let c = plane.corners.map { Corner(p: pos[$0], n: normals[$0], s: SIMD4(weights[$0], plane.inside)) }
            // A fan from the first corner, each triangle cut in four `detail` times. hide: the
            // wireframe's bits for the edges opposite a, b and c; those across the plane are hidden.
            var tris: [(a: Corner, b: Corner, c: Corner, hide: Int)] = (1..<c.count - 1).map { t in
                (c[0], c[t], c[t + 1], (t + 1 < c.count - 1 ? 2 : 0) | (t > 1 ? 4 : 0))
            }
            for _ in 0..<detail {
                tris = tris.flatMap { t -> [(a: Corner, b: Corner, c: Corner, hide: Int)] in
                    let ab = mid(t.a, t.b), bc = mid(t.b, t.c), ca = mid(t.c, t.a)
                    return [(t.a, ab, ca, 1 | (t.hide & 6)), (ab, t.b, bc, 2 | (t.hide & 5)),
                            (ca, bc, t.c, 4 | (t.hide & 3)), (ab, bc, ca, 7)]
                }
            }
            for t in tris {
                tri(t.a.p, t.b.p, t.c.p, t.a.n, t.b.n, t.c.n, shape: (t.a.s, t.b.s, t.c.s), rand: plane.rand, hide: t.hide)
            }
        }
    }
}
