import simd

/// Non-indexed vertex. Every triangle owns its three vertices, so each face can be
/// shattered, flat-shaded and wireframed independently.
/// Layout must match `MeshVertex` in Shaders/generators/lowpoly/_shared.metal.
struct MeshVertex {
    /// xyz position, w = per-face random 0...1.
    var position: SIMD4<Float>
    /// Outward face normal.
    var faceNormal: SIMD4<Float>
    /// Smooth normal, used as the displacement direction so faces stay connected.
    var smoothNormal: SIMD4<Float>
    /// Barycentric coordinate, for wireframes. w = the edges the wireframe skips: bits 0, 1, 2
    /// for the edge opposite the triangle's first, second and third vertex.
    var bary: SIMD4<Float>
    /// Shape coordinates the geo's vertex shader rebuilds the position from, so its shape
    /// knobs (torus thickness, wheel pitch…) move live. Meaning depends on the mesh; see each builder.
    var shape: SIMD4<Float>
}

/// The mesh a low-poly geo draws, named by its shader's `// @mesh` line. Its knobs that change
/// the triangle count are the shader's `mesh` params, read here by name.
enum MeshShape: String, CaseIterable {
    case sphere, torus, plane, cube, shards, wheel, drive, street, hand, face, dancer, globe

    /// The mesh params each shape reads. A geo shader must declare exactly these as `mesh` params.
    var meshParams: [String] {
        switch self {
        case .sphere: return ["detail"]
        case .torus: return ["rings", "sides"]
        case .plane: return ["width", "height", "density"]
        case .cube: return ["divisions"]
        case .shards: return ["count"]
        case .wheel: return ["blades", "segments"]
        case .drive: return ["segments", "palms"]
        case .street: return ["segments", "detail"]
        case .hand: return ["sides", "segments"]
        case .face: return ["detail"]
        case .dancer: return ["sides"]
        case .globe: return ["detail", "facets"]
        }
    }

    /// How many copies of the mesh to draw, from the live knobs, for a shape that sets its own;
    /// nil draws the `instances` knob's count. Street draws the street and one copy per lot.
    func instanceCount(_ value: (String) -> Float) -> Int? {
        switch self {
        case .street: return 1 + 2 * streetLots(distance: value("distance"), behind: value("behind"), lot: value("lot"))
        default: return nil
        }
    }
}

struct MeshBuilder {
    var vertices: [MeshVertex] = []
    private var rng = SplitMix(seed: 0x5EED)

    /// One triangle. `rand` is its face random, when it shares one with its neighbours (a plane
    /// of several triangles); `hide` is the edges the wireframe skips, as in `MeshVertex.bary`.
    mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                      _ na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>,
                      shape: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero),
                      rand: Float? = nil, hide: Int = 0) {
        var fn = simd_normalize(simd_cross(b - a, c - a))
        if !fn.x.isFinite { fn = simd_normalize(na + nb + nc) }
        if simd_dot(fn, na + nb + nc) < 0 { fn = -fn }
        let r = rand ?? rng.nextFloat()
        let bary: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for (i, (p, n, s)) in [(a, na, shape.0), (b, nb, shape.1), (c, nc, shape.2)].enumerated() {
            vertices.append(MeshVertex(position: SIMD4(p, r), faceNormal: SIMD4(fn, 0),
                                       smoothNormal: SIMD4(n, 0), bary: SIMD4(bary[i], Float(hide)), shape: s))
        }
    }

    /// What decides the mesh's triangles: it is rebuilt only when this changes. Plane width and
    /// height stretch the mesh live in the shader and only change it through the cell count.
    static func topology(_ shape: MeshShape, _ value: (String) -> Float) -> [Int] {
        func i(_ name: String) -> Int { Int(value(name).rounded()) }
        switch shape {
        case .sphere: return [min(max(i("detail"), 0), 5)]
        case .torus: return [min(max(i("rings"), 3), 128), min(max(i("sides"), 3), 64)]
        case .plane:
            let d = value("density")
            func cells(_ size: Float) -> Int { min(max(Int((size * d).rounded()), 2), 320) }
            return [cells(value("width")), cells(value("height"))]
        case .cube: return [min(max(i("divisions"), 1), 32)]
        case .shards: return [min(max(i("count"), 1), 4000)]
        case .wheel: return [min(max(i("blades"), 1), 96), min(max(i("segments"), 1), 16)]
        case .drive: return [min(max(i("segments"), 8), 512), min(max(i("palms"), 0), 256)]
        case .street: return [min(max(i("segments"), 8), 512), min(max(i("detail"), 0), 2)]
        case .hand: return [min(max(i("sides"), 3), 16), min(max(i("segments"), 1), 8)]
        case .face: return [min(max(i("detail"), 0), 4)]
        case .dancer: return [min(max(i("sides"), 3), 16)]
        case .globe: return [min(max(i("detail"), 0), WorldMap.tolerances.count - 1), min(max(i("facets"), 0), 5)]
        }
    }

    static func build(_ shape: MeshShape, topology t: [Int]) -> [MeshVertex] {
        var b = MeshBuilder()
        switch shape {
        case .sphere: b.sphere(t[0])
        case .torus: b.torus(rings: t[0], sides: t[1])
        case .plane: b.plane(cols: t[0], rows: t[1])
        case .cube: b.cube(t[0])
        case .shards: b.shards(t[0])
        case .wheel: b.wheel(blades: t[0], segments: t[1])
        case .drive: b.drive(segments: t[0], palms: t[1])
        case .street: b.street(segments: t[0], detail: t[1])
        case .hand: b.hand(sides: t[0], segments: t[1])
        case .face: b.face(detail: t[0])
        case .dancer: b.dancer(sides: t[0])
        case .globe: b.globe(detail: t[0], facets: t[1])
        }
        return b.vertices
    }

    /// Icosphere of radius 1. shape is unused.
    mutating func sphere(_ detail: Int) {
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
        for _ in 0..<detail {
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

    /// Torus, ring radius 1, tube radius 0.42.
    /// shape: x = position around the ring 0...1, y = around the tube 0...1, zw = the same at the face's centre.
    private mutating func torus(rings nu: Int, sides nv: Int) {
        let R: Float = 1, r: Float = 0.42
        func p(_ u: Float, _ w: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = u * 2 * .pi, b = w * 2 * .pi
            let n = SIMD3<Float>(cos(a) * cos(b), sin(b), sin(a) * cos(b))
            return (SIMD3(cos(a) * R, 0, sin(a) * R) + n * r, n)
        }
        for i in 0..<nu {
            for j in 0..<nv {
                let u0 = Float(i) / Float(nu), u1 = Float(i + 1) / Float(nu)
                let w0 = Float(j) / Float(nv), w1 = Float(j + 1) / Float(nv)
                let (a, na) = p(u0, w0), (b, nb) = p(u1, w0), (c, nc) = p(u1, w1), (d, nd) = p(u0, w1)
                func s(_ u: Float, _ w: Float, _ cu: Float, _ cw: Float) -> SIMD4<Float> { [u, w, cu, cw] }
                let c1 = ((u0 + u1 + u1) / 3, (w0 + w0 + w1) / 3), c2 = ((u0 + u1 + u0) / 3, (w0 + w1 + w1) / 3)
                tri(a, b, c, na, nb, nc, shape: (s(u0, w0, c1.0, c1.1), s(u1, w0, c1.0, c1.1), s(u1, w1, c1.0, c1.1)))
                tri(a, c, d, na, nc, nd, shape: (s(u0, w0, c2.0, c2.1), s(u1, w1, c2.0, c2.1), s(u0, w1, c2.0, c2.1)))
            }
        }
    }

    /// Flat sheet, -0.5...0.5 on x and z (the shader stretches it to width × height), facing up.
    /// shape: xy = position on the sheet before jitter, zw = this vertex's jitter offset at full jitter.
    /// Edge vertices don't jitter, so the sheet keeps straight edges.
    private mutating func plane(cols: Int, rows: Int) {
        var jitter = SplitMix(seed: 42)
        let cellX: Float = 1 / Float(rows), cellZ: Float = 1 / Float(cols)
        var grid = [SIMD4<Float>](repeating: .zero, count: (cols + 1) * (rows + 1))
        for j in 0...cols {
            for i in 0...rows {
                let edge = i == 0 || j == 0 || i == rows || j == cols
                let jx = edge ? 0 : (jitter.nextFloat() - 0.5) * cellX
                let jz = edge ? 0 : (jitter.nextFloat() - 0.5) * cellZ
                grid[j * (rows + 1) + i] = [Float(i) * cellX - 0.5, Float(j) * cellZ - 0.5, jx, jz]
            }
        }
        let up = SIMD3<Float>(0, 1, 0)
        func pos(_ s: SIMD4<Float>) -> SIMD3<Float> { [s.x + s.z * 0.7, 0, s.y + s.w * 0.7] }
        func t(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ c: SIMD4<Float>) {
            tri(pos(a), pos(b), pos(c), up, up, up, shape: (a, b, c))
        }
        for j in 0..<cols {
            for i in 0..<rows {
                let a = grid[j * (rows + 1) + i], b = grid[j * (rows + 1) + i + 1]
                let c = grid[(j + 1) * (rows + 1) + i + 1], d = grid[(j + 1) * (rows + 1) + i]
                if (i + j) % 2 == 0 { t(a, b, c); t(a, c, d) } else { t(a, b, d); t(b, c, d) }
            }
        }
    }

    /// Cube, half-size 0.8, each face a `divisions` × `divisions` grid of two-triangle cells.
    /// shape: xyz = the face's outward axis, w = which face 0...5.
    private mutating func cube(_ n: Int) {
        let axes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            ([1, 0, 0], [0, 1, 0], [0, 0, 1]), ([-1, 0, 0], [0, 1, 0], [0, 0, -1]),
            ([0, 1, 0], [0, 0, 1], [1, 0, 0]), ([0, -1, 0], [0, 0, -1], [1, 0, 0]),
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
        ]
        for (k, (normal, u, w)) in axes.enumerated() {
            let s = SIMD4<Float>(normal, Float(k))
            func p(_ i: Int, _ j: Int) -> SIMD3<Float> {
                normal * 0.8 + u * (Float(i) / Float(n) * 1.6 - 0.8) + w * (Float(j) / Float(n) * 1.6 - 0.8)
            }
            for i in 0..<n {
                for j in 0..<n {
                    let a = p(i, j), b = p(i + 1, j), c = p(i + 1, j + 1), d = p(i, j + 1)
                    tri(a, b, c, simd_normalize(a), simd_normalize(b), simd_normalize(c), shape: (s, s, s))
                    tri(a, c, d, simd_normalize(a), simd_normalize(c), simd_normalize(d), shape: (s, s, s))
                }
            }
        }
    }

    /// A cloud of four-faced crystals around the origin, each pointing outward.
    /// shape: xyz = the shard's centre, w = how far this vertex reaches out at length 1
    /// (the tip's own size; 0 for the base corners).
    private mutating func shards(_ count: Int) {
        var r = SplitMix(seed: 7)
        for _ in 0..<count {
            // Random point in a sphere, biased outward.
            let dir = simd_normalize(SIMD3<Float>(r.nextFloat() - 0.5, r.nextFloat() - 0.5, r.nextFloat() - 0.5))
            let center = dir * (0.4 + 1.4 * r.nextFloat().squareRoot())
            let size = 0.08 + 0.35 * r.nextFloat() * r.nextFloat()
            var pts: [SIMD3<Float>] = []
            for _ in 0..<4 {
                let o = simd_normalize(SIMD3<Float>(r.nextFloat() - 0.5, r.nextFloat() - 0.5, r.nextFloat() - 0.5))
                pts.append(center + o * size * (0.5 + r.nextFloat()))
            }
            let base = SIMD4<Float>(center, 0), tip = SIMD4<Float>(center, size)
            let n = dir
            tri(pts[0], pts[1], pts[2], n, n, n, shape: (tip, base, base))
            tri(pts[0], pts[2], pts[3], n, n, n, shape: (tip, base, base))
            tri(pts[0], pts[3], pts[1], n, n, n, shape: (tip, base, base))
            tri(pts[1], pts[3], pts[2], n, n, n, shape: (base, base, base))
        }
    }

    /// Water wheel: flat paddles hinged along one edge to an invisible axle on x, each a
    /// `segments` × `segments` grid. The shader places them (radius, length, pitch, flap…).
    /// shape: x = which blade 0...1 around the axle, y = along the blade from the hinge 0...1,
    /// z = across the blade -0.5...0.5, w = y at the face's centre.
    private mutating func wheel(blades: Int, segments n: Int) {
        for k in 0..<blades {
            let blade = Float(k) / Float(blades)
            let a = blade * 2 * .pi
            let radial = SIMD3<Float>(0, cos(a), sin(a))
            let normal = SIMD3<Float>(0, -sin(a), cos(a))
            func p(_ t: Float, _ s: Float) -> SIMD3<Float> { SIMD3(s * 1.5, 0, 0) + radial * (0.6 + t * 1.4) }
            for i in 0..<n {
                for j in 0..<n {
                    let t0 = Float(i) / Float(n), t1 = Float(i + 1) / Float(n)
                    let s0 = Float(j) / Float(n) - 0.5, s1 = Float(j + 1) / Float(n) - 0.5
                    let c1 = (t0 + t1 + t1) / 3, c2 = (t0 + t1 + t0) / 3
                    func s(_ t: Float, _ w: Float, _ c: Float) -> SIMD4<Float> { [blade, t, w, c] }
                    tri(p(t0, s0), p(t1, s0), p(t1, s1), normal, normal, normal,
                        shape: (s(t0, s0, c1), s(t1, s0, c1), s(t1, s1, c1)))
                    tri(p(t0, s0), p(t1, s1), p(t0, s1), normal, normal, normal,
                        shape: (s(t0, s0, c2), s(t1, s1, c2), s(t0, s1, c2)))
                }
            }
        }
    }
    /// Phalanx lengths (proximal, middle, distal) of the thumb, index, middle, ring and pinky.
    /// Must match `handLen` in Shaders/generators/lowpoly/hand.metal.
    static let handLengths: [SIMD3<Float>] = [
        [0.40, 0.28, 0.26], [0.42, 0.25, 0.22], [0.46, 0.28, 0.23], [0.43, 0.26, 0.22], [0.36, 0.22, 0.20],
    ]

    /// A fist: a palm and wrist, and five fingers that are `sides`-sided tubes of three
    /// phalanges, `segments` rings each, ending in a pointed tip. The shader bends the fingers.
    /// Palm: shape.x = 5; position and normals are the hand's own, as drawn.
    /// Fingers: shape.x = finger (0 thumb … 4 pinky) + 10 × the face's phalanx 0...2,
    /// y = along the finger 0...3 (whole numbers are the joints, 3 the tip), zw = the vertex's
    /// offset across the finger (sideways, toward the palm). position and faceNormal are in the
    /// straight finger's own frame (along, toward the palm, sideways), so the shader can bend them.
    private mutating func hand(sides n: Int, segments: Int) {
        func ring(_ k: Int, phase: Float = 0) -> SIMD2<Float> {
            let a = (Float(k) + phase) / Float(n) * 2 * .pi
            return [cos(a), sin(a)]
        }

        // Palm and wrist: an elliptical tube up the y axis, capped at both ends.
        // (y, sideways radius, front-to-back radius)
        let palm: [SIMD3<Float>] = [[-1.05, 0.22, 0.17], [-0.6, 0.25, 0.19], [-0.42, 0.42, 0.2],
                                    [0.15, 0.46, 0.21], [0.5, 0.44, 0.19]]
        let palmShape = SIMD4<Float>(5, 0, 0, 0)
        func pp(_ r: SIMD3<Float>, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let c = ring(k, phase: 0.5)
            return ([c.y * r.z, r.x, c.x * r.y], simd_normalize([c.y / r.z, 0, c.x / r.y]))
        }
        for i in 0..<palm.count - 1 {
            for k in 0..<n {
                let (a, na) = pp(palm[i], k), (b, nb) = pp(palm[i], k + 1)
                let (c, nc) = pp(palm[i + 1], k + 1), (d, nd) = pp(palm[i + 1], k)
                tri(a, b, c, na, nb, nc, shape: (palmShape, palmShape, palmShape))
                tri(a, c, d, na, nc, nd, shape: (palmShape, palmShape, palmShape))
            }
        }
        for (end, y, dir) in [(palm[0], palm[0].x - 0.04, Float(-1)), (palm[palm.count - 1], palm[palm.count - 1].x + 0.05, 1)] {
            let centre = SIMD3<Float>(0, y, 0), up = SIMD3<Float>(0, dir, 0)
            for k in 0..<n {
                let (a, na) = pp(end, k), (b, nb) = pp(end, k + 1)
                tri(a, b, centre, na, nb, up, shape: (palmShape, palmShape, palmShape))
            }
        }

        // Fingers. Rings along each: `segments` per phalanx, the last one short of the tip.
        let radius: [Float] = [0.115, 0.105, 0.11, 0.103, 0.09]
        var along: [Float] = []
        for j in 0..<3 {
            for i in 0..<segments { along.append(Float(j) + Float(i) / Float(segments) * (j == 2 ? 0.85 : 1)) }
        }
        along.append(2.85)
        for (finger, len) in MeshBuilder.handLengths.enumerated() {
            // Distance along the straight finger at s.
            func dist(_ s: Float) -> Float {
                let j = min(Int(s), 2), t = s - Float(j)
                var d: Float = 0
                for i in 0..<j { d += len[i] }
                return d + t * len[j]
            }
            func rad(_ s: Float) -> Float { radius[finger] * (1 - 0.07 * s) * (s > 2.8 ? 0.8 : 1) }
            func vert(_ s: Float, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>) {
                let c = ring(k), off = c * rad(s)
                return ([dist(s), off.y, off.x], [0, c.y, c.x], off)
            }
            func sh(_ s: Float, _ off: SIMD2<Float>, _ phalanx: Int) -> SIMD4<Float> {
                [Float(finger + 10 * phalanx), s, off.x, off.y]
            }
            for r in 0..<along.count - 1 {
                let s0 = along[r], s1 = along[r + 1], ph = min(Int(s0), 2)
                for k in 0..<n {
                    let (a, na, oa) = vert(s0, k), (b, nb, ob) = vert(s0, k + 1)
                    let (c, nc, oc) = vert(s1, k + 1), (d, nd, od) = vert(s1, k)
                    tri(a, b, c, na, nb, nc, shape: (sh(s0, oa, ph), sh(s0, ob, ph), sh(s1, oc, ph)))
                    tri(a, c, d, na, nc, nd, shape: (sh(s0, oa, ph), sh(s1, oc, ph), sh(s1, od, ph)))
                }
            }
            // The pointed tip and the cap at the knuckle.
            let tip = SIMD3<Float>(dist(3), 0, 0), base = SIMD3<Float>(0, 0, 0)
            for k in 0..<n {
                let (a, na, oa) = vert(2.85, k), (b, nb, ob) = vert(2.85, k + 1)
                tri(a, b, tip, na, nb, [1, 0, 0], shape: (sh(2.85, oa, 2), sh(2.85, ob, 2), sh(3, .zero, 2)))
                let (c, nc, oc) = vert(0, k), (d, nd, od) = vert(0, k + 1)
                tri(d, c, base, nd, nc, [-1, 0, 0], shape: (sh(0, od, 0), sh(0, oc, 0), sh(0, .zero, 0)))
            }
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
