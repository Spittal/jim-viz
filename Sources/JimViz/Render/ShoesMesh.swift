import simd

/// Shoes: a pair of high-top sneakers. Each is a stack of `sides`-sided rings from the sole up
/// to the collar, with a tongue up the front and laces across it.
extension MeshBuilder {
    /// One cross-section of a tube. Its points' smooth normals point away from its centre
    /// (toward it when `inward`), leaning by `lean`.
    private struct ShoeRing {
        var points: [SIMD3<Float>]
        var lean: SIMD3<Float> = .zero
        var inward = false

        var centre: SIMD3<Float> { points.reduce(.zero, +) / Float(points.count) }
        func normal(_ k: Int) -> SIMD3<Float> {
            let out = simd_normalize(points[k % points.count] - centre)
            return simd_normalize((inward ? -out : out) + lean)
        }
    }

    /// Both shoes are the right shoe, in its own frame: x toward the toe, y up from the floor,
    /// z out to its side. The shader mirrors the left one and places them.
    /// shape: x = the shoe (0 right, 1 left), y = the part (0 sole, 1 canvas, 2 toe cap,
    /// 3 tongue, 4 laces, 5 the inside of the collar).
    /// The sole's top (0.1) and the ankle (0.36) must match `soleTop` and `ankleY` in
    /// Shaders/generators/lowpoly/shoes.metal.
    mutating func shoes(sides n: Int) {
        // A ring round the shoe at height y, from its back to its front, squarer than an
        // ellipse and fuller on the outside. Half a side round, so the toe and heel are blunt.
        func ring(_ y: Float, _ back: Float, _ front: Float, _ heelWidth: Float, _ toeWidth: Float) -> [SIMD3<Float>] {
            (0..<n).map { k in
                let a = (Float(k) + 0.5) / Float(n) * 2 * .pi
                func square(_ v: Float) -> Float { v < 0 ? -pow(-v, 0.7) : pow(v, 0.7) }
                let c = square(cos(a)), s = square(sin(a))
                let width = heelWidth + (toeWidth - heelWidth) * (c + 1) / 2
                return [(back + front) / 2 + (front - back) / 2 * c, y, width * s * (s > 0 ? 1.06 : 0.94)]
            }
        }
        let up = SIMD3<Float>(0, 1, 0)
        // The sole, a ledge in to the canvas, the toe box, the instep sloping back to the ankle,
        // the collar, then its rim and the inside.
        let body = [
            ShoeRing(points: ring(0, -0.40, 0.56, 0.135, 0.175)),
            ShoeRing(points: ring(0.035, -0.43, 0.60, 0.16, 0.20)),
            ShoeRing(points: ring(0.10, -0.43, 0.60, 0.16, 0.20), lean: up * 2),
            ShoeRing(points: ring(0.10, -0.40, 0.56, 0.14, 0.18), lean: up * 2),
            ShoeRing(points: ring(0.20, -0.41, 0.54, 0.145, 0.18)),
            ShoeRing(points: ring(0.27, -0.41, 0.36, 0.145, 0.165), lean: up),
            ShoeRing(points: ring(0.36, -0.40, 0.20, 0.14, 0.15)),
            ShoeRing(points: ring(0.50, -0.385, 0.10, 0.135, 0.14)),
            ShoeRing(points: ring(0.66, -0.38, 0.05, 0.135, 0.135)),
            ShoeRing(points: ring(0.82, -0.395, 0.035, 0.14, 0.14), lean: up * 2),
            ShoeRing(points: ring(0.82, -0.36, 0, 0.11, 0.11), lean: up * 2, inward: true),
            ShoeRing(points: ring(0.72, -0.35, -0.01, 0.10, 0.10), lean: up * 2, inward: true),
        ]

        // The tongue runs up the front of the instep and out past the collar: (x, y) along it,
        // and its half-width there.
        let tongue: [(at: SIMD2<Float>, halfWidth: Float)] = [([0.34, 0.29], 0.06), ([0.19, 0.42], 0.075),
                                                              ([0.105, 0.60], 0.085), ([0.085, 0.93], 0.075)]
        // Along a stretch of the tongue, and out of its face.
        func along(_ i: Int) -> SIMD2<Float> { simd_normalize(tongue[i + 1].at - tongue[i].at) }
        func out(_ d: SIMD2<Float>) -> SIMD2<Float> { [d.y, -d.x] }
        func point(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { [p.x, p.y, z] }
        let tongueRings = tongue.indices.map { i -> ShoeRing in
            let d = simd_normalize((i > 0 ? along(i - 1) : .zero) + (i < tongue.count - 1 ? along(i) : .zero))
            let front = tongue[i].at + out(d) * 0.03, back = tongue[i].at - out(d) * 0.03, w = tongue[i].halfWidth
            return ShoeRing(points: [point(front, -w), point(front, w), point(back, w), point(back, -w)])
        }
        // Laces: bars across the tongue, slanted one way then the other, their ends pulled
        // back into the canvas. (The stretch of the tongue, how far along it.)
        let laces: [(Int, Float)] = [(0, 0.3), (0, 0.8), (1, 0.35), (1, 0.8), (2, 0.25), (2, 0.55)]
        let laceRings = laces.enumerated().map { index, lace -> [ShoeRing] in
            let d = along(lace.0), o = out(d)
            let centre = tongue[lace.0].at + (tongue[lace.0 + 1].at - tongue[lace.0].at) * lace.1
            let slant: Float = index % 2 == 0 ? 0.03 : -0.03
            return [(-0.125, -0.065), (-0.06, 0), (0.06, 0), (0.125, -0.065)].map { (z: Float, sunk: Float) in
                let c = centre + o * (0.045 + sunk) + d * slant * z / 0.125
                return ShoeRing(points: [point(c + d * 0.016 + o * 0.012, z), point(c - d * 0.016 + o * 0.012, z),
                                         point(c - d * 0.016 - o * 0.012, z), point(c + d * 0.016 - o * 0.012, z)])
            }
        }

        for shoe in 0..<2 {
            shoeTube(body, shoe: shoe, start: (0, -up), end: (5, up)) { band, centre in
                if band < 3 { return 0 }
                if band >= 10 { return 5 }
                // The toe cap: the front and top of the toe box.
                return centre.x > 0.36 && centre.y < 0.27 ? 2 : 1
            }
            shoeTube(tongueRings, shoe: shoe, start: (3, -up), end: (3, up)) { _, _ in 3 }
            for lace in laceRings {
                shoeTube(lace, shoe: shoe, start: (4, [0, 0, -1]), end: (4, [0, 0, 1])) { _, _ in 4 }
            }
        }
    }

    /// A tube through its rings, closed at both ends with a fan (its part, the way it faces).
    /// `part` picks each side face's part from the band of rings it is in and its centre.
    private mutating func shoeTube(_ rings: [ShoeRing], shoe: Int, start: (Float, SIMD3<Float>), end: (Float, SIMD3<Float>),
                                   part: (Int, SIMD3<Float>) -> Float) {
        let n = rings[0].points.count
        func face(_ a: (SIMD3<Float>, SIMD3<Float>), _ b: (SIMD3<Float>, SIMD3<Float>), _ c: (SIMD3<Float>, SIMD3<Float>),
                  _ part: Float) {
            let s = SIMD4<Float>(Float(shoe), part, 0, 0)
            tri(a.0, b.0, c.0, a.1, b.1, c.1, shape: (s, s, s))
        }
        for i in 0..<rings.count - 1 {
            func vert(_ ring: Int, _ k: Int) -> (SIMD3<Float>, SIMD3<Float>) { (rings[ring].points[k % n], rings[ring].normal(k)) }
            for k in 0..<n {
                let a = vert(i, k), b = vert(i, k + 1), c = vert(i + 1, k + 1), d = vert(i + 1, k)
                face(a, b, c, part(i, (a.0 + b.0 + c.0) / 3))
                face(a, c, d, part(i, (a.0 + c.0 + d.0) / 3))
            }
        }
        for (ring, cap) in [(rings[0], start), (rings[rings.count - 1], end)] {
            for k in 0..<n {
                face((ring.points[k], cap.1), (ring.points[(k + 1) % n], cap.1), (ring.centre, cap.1), cap.0)
            }
        }
    }
}
