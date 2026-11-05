import simd

/// Non-indexed vertex. Every triangle owns its three vertices, so each face can be
/// shattered, flat-shaded and wireframed independently.
/// Layout must match `MeshVertex` in Shaders/generators/*.metal.
struct MeshVertex {
    /// xyz position, w = per-face random 0...1.
    var position: SIMD4<Float>
    /// Outward face normal.
    var faceNormal: SIMD4<Float>
    /// Smooth normal, used as the displacement direction so faces stay connected.
    var smoothNormal: SIMD4<Float>
    /// Barycentric coordinate, for wireframes.
    var bary: SIMD4<Float>
}

enum MeshShape: String, CaseIterable {
    case icosphere, torus, plane, cube, shards
}

struct MeshBuilder {
    private(set) var vertices: [MeshVertex] = []
    private var rng = SplitMix(seed: 0x5EED)

    mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                      _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>) {
        var fn = simd_normalize(simd_cross(b - a, c - a))
        if !fn.x.isFinite { fn = simd_normalize(na + nb + nc) }
        if simd_dot(fn, na + nb + nc) < 0 { fn = -fn }
        let r = rng.nextFloat()
        let bary: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for (i, (p, n)) in [(a, na), (b, nb), (c, nc)].enumerated() {
            vertices.append(MeshVertex(position: SIMD4(p, r), faceNormal: SIMD4(fn, 0),
                                       smoothNormal: SIMD4(n, 0), bary: SIMD4(bary[i], 0)))
        }
    }

    static func build(_ shape: MeshShape, detail: Int) -> [MeshVertex] {
        var b = MeshBuilder()
        let d = min(max(detail, 0), 6)
        switch shape {
        case .icosphere: b.icosphere(d)
        case .torus: b.torus(d)
        case .plane: b.plane(d)
        case .cube: b.cube(d)
        case .shards: b.shards(d)
        }
        return b.vertices
    }

    private mutating func icosphere(_ detail: Int) {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var v: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
            [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
            [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ].map { simd_normalize($0) }
        var f: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        for _ in 0..<min(detail, 5) {
            var cache: [Int: Int] = [:]
            func mid(_ a: Int, _ b: Int) -> Int {
                let key = min(a, b) << 20 | max(a, b)
                if let i = cache[key] { return i }
                v.append(simd_normalize((v[a] + v[b]) / 2))
                cache[key] = v.count - 1
                return v.count - 1
            }
            f = f.flatMap { a, b, c -> [(Int, Int, Int)] in
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                return [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
        }
        for (a, b, c) in f { tri(v[a], v[b], v[c], v[a], v[b], v[c]) }
    }

    private mutating func torus(_ detail: Int) {
        let nu = 6 * (detail + 1), nv = 3 * (detail + 1) + 2
        let R: Float = 1, r: Float = 0.42
        func p(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let u = Float(i % nu) / Float(nu) * 2 * .pi
            let w = Float(j % nv) / Float(nv) * 2 * .pi
            let center = SIMD3<Float>(cos(u) * R, 0, sin(u) * R)
            let n = SIMD3<Float>(cos(u) * cos(w), sin(w), sin(u) * cos(w))
            return (center + n * r, n)
        }
        for i in 0..<nu {
            for j in 0..<nv {
                let (a, na) = p(i, j), (b, nb) = p(i + 1, j), (c, nc) = p(i + 1, j + 1), (d, nd) = p(i, j + 1)
                tri(a, b, c, na, nb, nc)
                tri(a, c, d, na, nc, nd)
            }
        }
    }

    private mutating func plane(_ detail: Int) {
        let n = min(4 << detail, 160)
        let size: Float = 1
        var grid = [SIMD3<Float>](repeating: .zero, count: (n + 1) * (n + 1))
        var jitter = SplitMix(seed: 42)
        for j in 0...n {
            for i in 0...n {
                let cell = size / Float(n)
                let edge = i == 0 || j == 0 || i == n || j == n
                let jx = edge ? 0 : (jitter.nextFloat() - 0.5) * cell * 0.7
                let jz = edge ? 0 : (jitter.nextFloat() - 0.5) * cell * 0.7
                grid[j * (n + 1) + i] = [Float(i) * cell - size / 2 + jx, 0, Float(j) * cell - size / 2 + jz]
            }
        }
        let up = SIMD3<Float>(0, 1, 0)
        for j in 0..<n {
            for i in 0..<n {
                let a = grid[j * (n + 1) + i], b = grid[j * (n + 1) + i + 1]
                let c = grid[(j + 1) * (n + 1) + i + 1], d = grid[(j + 1) * (n + 1) + i]
                if (i + j) % 2 == 0 {
                    tri(a, b, c, up, up, up); tri(a, c, d, up, up, up)
                } else {
                    tri(a, b, d, up, up, up); tri(b, c, d, up, up, up)
                }
            }
        }
    }

    private mutating func cube(_ detail: Int) {
        let n = max(1, 1 << min(detail, 5))
        let axes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 1, 0], [0, 0, -1]),
            ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [0, 0, -1], [1, 0, 0]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        for (normal, u, w) in axes {
            func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
                normal * 0.8 + u * (Float(i) / Float(n) * 1.6 - 0.8) + w * (Float(j) / Float(n) * 1.6 - 0.8)
            }
            for i in 0..<n {
                for j in 0..<n {
                    let a = p(i, j), b = p(i + 1, j), c = p(i + 1, j + 1), d = p(i, j + 1)
                    tri(a, b, c, simd_normalize(a), simd_normalize(b), simd_normalize(c))
                    tri(a, c, d, simd_normalize(a), simd_normalize(c), simd_normalize(d))
                }
            }
        }
    }

    private mutating func shards(_ detail: Int) {
        var r = SplitMix(seed: 7)
        let count = 24 * (detail + 1) * (detail + 1)
        for _ in 0..<count {
            // Random point in a sphere, biased outward.
            var dir = SIMD3<Float>(r.nextFloat() - 0.5, r.nextFloat() - 0.5, r.nextFloat() - 0.5)
            dir = simd_normalize(dir)
            let center = dir * (0.4 + 1.4 * r.nextFloat().squareRoot())
            let size = 0.08 + 0.35 * r.nextFloat() * r.nextFloat()
            var pts: [SIMD3<Float>] = []
            for _ in 0..<4 {
                let o = simd_normalize(SIMD3<Float>(r.nextFloat() - 0.5, r.nextFloat() - 0.5, r.nextFloat() - 0.5))
                pts.append(center + o * size * (0.5 + r.nextFloat()))
            }
            // Stretch along the outward direction for a crystal look.
            pts[0] += dir * size * 2.5
            let n = dir
            tri(pts[0], pts[1], pts[2], n, n, n)
            tri(pts[0], pts[2], pts[3], n, n, n)
            tri(pts[0], pts[3], pts[1], n, n, n)
            tri(pts[1], pts[3], pts[2], n, n, n)
        }
    }
}

/// Small deterministic RNG so meshes are identical between runs.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
