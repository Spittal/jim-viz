import simd

/// Drive: an endless road with a low-poly 80s wedge car on it, palms, a sliced sun and a
/// mountain range. The shader scrolls, bends and places everything; the mesh only holds parts.
/// Which part a face is sits in shape.w (`DrivePart`); the rest depends on the part:
/// - road, rumble, ground: position.x = distance along the road 0...1 before it scrolls,
///   position.z = across (road -1...1, rumble and ground 0...1 out from the road's edge),
///   shape.y = side (-1 left, 1 right).
/// - body, stripe, glass, light: position = car space (nose at -x, the road at y 0).
/// - wheel: position = relative to its hub, shape.xyz = the hub in car space.
/// - trunk, frond: position = palm space (base at 0, leaning toward -z), shape.x = where along
///   the road 0...1, shape.y = side, shape.z = per-palm random.
/// - sun: position.x = which side of the disc ±1, position.y = which edge of the band ±1,
///   shape.x = the band's centre -1...1, shape.y = its half-height.
/// - mountain: position.x = across the horizon -1...1, position.y = height 0...1,
///   position.z = how far back 0...1.
enum DrivePart: Int {
    case road, rumble, ground, body, stripe, glass, light, wheel, trunk, frond, sun, mountain
}

extension MeshBuilder {
    mutating func drive(segments: Int, palms: Int) {
        driveRoad(segments)
        driveCar()
        drivePalms(palms)
        driveSun()
        driveMountains()
    }

    private mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                               _ part: DrivePart, _ shape: SIMD3<Float> = .zero, normal: SIMD3<Float>? = nil) {
        let n = normal ?? simd_normalize(simd_cross(b - a, c - a))
        let s = SIMD4<Float>(shape, Float(part.rawValue))
        tri(a, b, c, n, n, n, shape: (s, s, s))
        tri(a, c, d, n, n, n, shape: (s, s, s))
    }

    private mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                   _ part: DrivePart, _ shape: SIMD3<Float> = .zero, normal: SIMD3<Float>? = nil) {
        var n = normal ?? simd_normalize(simd_cross(b - a, c - a))
        if !n.x.isFinite { n = [0, 1, 0] }
        let s = SIMD4<Float>(shape, Float(part.rawValue))
        tri(a, b, c, n, n, n, shape: (s, s, s))
    }

    /// One strip of faces per segment: the road, a rumble strip each side and the ground out to
    /// the horizon, in columns that widen going out.
    private mutating func driveRoad(_ segments: Int) {
        let up = SIMD3<Float>(0, 1, 0)
        let columns: [Float] = [0, 0.03, 0.08, 0.16, 0.28, 0.45, 0.7, 1]
        for i in 0..<segments {
            let x0 = Float(i) / Float(segments), x1 = Float(i + 1) / Float(segments)
            func strip(_ part: DrivePart, _ side: Float, _ z0: Float, _ z1: Float) {
                quad([x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1], part, [0, side, 0], normal: up)
            }
            strip(.road, 0, -1, 1)
            for side: Float in [-1, 1] {
                strip(.rumble, side, 0, 1)
                for k in 0..<columns.count - 1 { strip(.ground, side, columns[k], columns[k + 1]) }
            }
        }
    }

    /// The car: a wedge lofted through cross-sections, pinstripes down the flanks, racing
    /// stripes over the hood, roof and deck, a light bar across the tail, a wing, four wheels.
    private mutating func driveCar() {
        // x, half-width, sill, beltline, top, half-width at the top.
        let sections: [(x: Float, w: Float, y0: Float, y1: Float, y2: Float, wt: Float)] = [
            (-2.20, 0.82, 0.26, 0.48, 0.52, 0.74), // nose
            (-1.95, 0.90, 0.22, 0.60, 0.64, 0.80), // front of the hood
            (-0.55, 0.92, 0.22, 0.70, 0.78, 0.80), // base of the windscreen
            (0.20, 0.92, 0.22, 0.72, 1.14, 0.60),  // front of the roof
            (0.95, 0.92, 0.22, 0.74, 1.12, 0.60),  // back of the roof
            (1.55, 0.92, 0.22, 0.76, 0.84, 0.84),  // rear deck
            (2.15, 0.90, 0.26, 0.76, 0.82, 0.84),  // tail
        ]
        func ring(_ s: (x: Float, w: Float, y0: Float, y1: Float, y2: Float, wt: Float)) -> [SIMD3<Float>] {
            [[s.x, s.y0, -s.w], [s.x, s.y1, -s.w], [s.x, s.y2, -s.wt], [s.x, s.y2, s.wt], [s.x, s.y1, s.w], [s.x, s.y0, s.w]]
        }
        let centre = SIMD3<Float>(0, 0.6, 0)
        func outward(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize((a + b + c) / 3 - centre)
        }
        for j in 0..<sections.count - 1 {
            let a = ring(sections[j]), b = ring(sections[j + 1])
            for k in 0..<6 {
                let k1 = (k + 1) % 6
                // Windscreen and rear window on top, side windows along the cabin.
                let glass = ((k == 1 || k == 3) && (2...4).contains(j)) || (k == 2 && (j == 2 || j == 4))
                let part: DrivePart = glass ? .glass : .body
                quad(a[k], b[k], b[k1], a[k1], part, normal: outward(a[k], b[k], b[k1]))
            }
        }
        for (s, cap) in [(sections[0], true), (sections[sections.count - 1], false)] {
            let r = ring(s)
            let mid = r.reduce(.zero, +) / Float(r.count)
            let n = SIMD3<Float>(cap ? -1 : 1, 0, 0)
            for k in 0..<6 { triangle(mid, r[k], r[(k + 1) % 6], .body, normal: n) }
        }

        // Pinstripes along both flanks, standing just off the panel.
        let lift: Float = 0.012
        for j in 1..<sections.count - 1 {
            let a = sections[j], b = sections[j + 1]
            for side: Float in [-1, 1] {
                for (lo, hi) in [(0.40, 0.44), (0.48, 0.50), (0.535, 0.55)] as [(Float, Float)] {
                    quad([a.x, lo, side * (a.w + lift)], [b.x, lo, side * (b.w + lift)],
                         [b.x, hi, side * (b.w + lift)], [a.x, hi, side * (a.w + lift)], .stripe, normal: [0, 0, side])
                }
            }
        }
        // Racing stripes over the hood, roof and deck.
        for j in [1, 3, 5] {
            let a = sections[j], b = sections[j + 1]
            for (z0, z1) in [(-0.24, -0.12), (0.12, 0.24)] as [(Float, Float)] {
                quad([a.x, a.y2 + lift, z0], [b.x, b.y2 + lift, z0], [b.x, b.y2 + lift, z1], [a.x, a.y2 + lift, z1],
                     .stripe, normal: [0, 1, 0])
            }
        }
        // Light bar across the tail.
        let tail = sections[sections.count - 1].x + lift
        quad([tail, 0.56, -0.8], [tail, 0.56, 0.8], [tail, 0.68, 0.8], [tail, 0.68, -0.8], .light, normal: [1, 0, 0])

        // Wing on two struts.
        box([1.80, 0.98, -0.9], [2.25, 1.03, 0.9], .body)
        for z: Float in [-0.55, 0.5] { box([1.95, 0.82, z], [2.03, 0.98, z + 0.05], .body) }
        quad([2.25 + lift, 0.98, -0.9], [2.25 + lift, 0.98, 0.9], [2.25 + lift, 1.03, 0.9], [2.25 + lift, 1.03, -0.9],
             .stripe, normal: [1, 0, 0])

        // Wheels: eight-sided drums, spun by the shader around their hubs.
        let radius: Float = 0.34, half: Float = 0.14, sides = 8
        for x: Float in [-1.4, 1.4] {
            for z: Float in [-0.84, 0.84] {
                let hub = SIMD3<Float>(x, radius, z)
                for k in 0..<sides {
                    let a0 = Float(k) / Float(sides) * 2 * .pi, a1 = Float(k + 1) / Float(sides) * 2 * .pi
                    let p0 = SIMD3<Float>(cos(a0) * radius, sin(a0) * radius, 0)
                    let p1 = SIMD3<Float>(cos(a1) * radius, sin(a1) * radius, 0)
                    let o = SIMD3<Float>(0, 0, half)
                    quad(p0 - o, p1 - o, p1 + o, p0 + o, .wheel, hub, normal: simd_normalize(p0 + p1))
                    triangle(o, p0 + o, p1 + o, .wheel, hub, normal: [0, 0, 1])
                    triangle(-o, p1 - o, p0 - o, .wheel, hub, normal: [0, 0, -1])
                }
            }
        }
    }

    private mutating func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ part: DrivePart) {
        func p(_ x: Bool, _ y: Bool, _ z: Bool) -> SIMD3<Float> { [x ? hi.x : lo.x, y ? hi.y : lo.y, z ? hi.z : lo.z] }
        quad(p(false, false, false), p(true, false, false), p(true, false, true), p(false, false, true), part, normal: [0, -1, 0])
        quad(p(false, true, false), p(false, true, true), p(true, true, true), p(true, true, false), part, normal: [0, 1, 0])
        quad(p(false, false, false), p(false, true, false), p(true, true, false), p(true, false, false), part, normal: [0, 0, -1])
        quad(p(false, false, true), p(true, false, true), p(true, true, true), p(false, true, true), part, normal: [0, 0, 1])
        quad(p(false, false, false), p(false, false, true), p(false, true, true), p(false, true, false), part, normal: [-1, 0, 0])
        quad(p(true, false, false), p(true, true, false), p(true, true, true), p(true, false, true), part, normal: [1, 0, 0])
    }

    /// Palms spread evenly along the road, alternating sides: a five-sided trunk that leans
    /// over the road, and a crown of folded fronds.
    private mutating func drivePalms(_ count: Int) {
        var r = SplitMix(seed: 11)
        let height: Float = 6.5, lean: Float = 1.2, rings = 4, sides = 5
        func trunk(_ t: Float) -> SIMD3<Float> { [0, t * height, -lean * t * t] }
        for i in 0..<count {
            let shape = SIMD3<Float>((Float(i) + r.nextFloat() * 0.6) / Float(count), i % 2 == 0 ? -1 : 1, r.nextFloat())
            for k in 0..<rings {
                let t0 = Float(k) / Float(rings), t1 = Float(k + 1) / Float(rings)
                let r0 = 0.28 - 0.12 * t0, r1 = 0.28 - 0.12 * t1
                for j in 0..<sides {
                    let a0 = Float(j) / Float(sides) * 2 * .pi, a1 = Float(j + 1) / Float(sides) * 2 * .pi
                    let d0 = SIMD3<Float>(cos(a0), 0, sin(a0)), d1 = SIMD3<Float>(cos(a1), 0, sin(a1))
                    quad(trunk(t0) + d0 * r0, trunk(t1) + d0 * r1, trunk(t1) + d1 * r1, trunk(t0) + d1 * r0,
                         .trunk, shape, normal: simd_normalize(d0 + d1))
                }
            }
            let top = trunk(1)
            let fronds = 7, spin = r.nextFloat() * 2 * .pi
            for k in 0..<fronds {
                let a = Float(k) / Float(fronds) * 2 * .pi + spin
                let dir = SIMD3<Float>(cos(a), 0, sin(a)), across = SIMD3<Float>(-sin(a), 0, cos(a))
                let mid = top + dir * 1.4 + [0, 0.55, 0], tip = top + dir * 2.9 + [0, -0.9, 0]
                let left = mid + across * 0.42 + [0, -0.15, 0], right = mid - across * 0.42 + [0, -0.15, 0]
                triangle(top, left, mid, .frond, shape)
                triangle(top, mid, right, .frond, shape)
                triangle(left, tip, mid, .frond, shape)
                triangle(mid, tip, right, .frond, shape)
            }
        }
    }

    /// The sun: a disc cut into horizontal bands, so the shader can open gaps between them.
    private mutating func driveSun() {
        let bands = 14
        for b in 0..<bands {
            let top = 1 - 2 * Float(b) / Float(bands), bottom = 1 - 2 * Float(b + 1) / Float(bands)
            let shape = SIMD3<Float>((top + bottom) / 2, (top - bottom) / 2, 0)
            quad([-1, 1, 0], [1, 1, 0], [1, -1, 0], [-1, -1, 0], .sun, shape, normal: [1, 0, 0])
        }
    }

    /// A jagged range across the horizon, two rows of facets from the foot to the ridge, each
    /// point set back by its own amount so the faces catch the light differently.
    private mutating func driveMountains() {
        var r = SplitMix(seed: 23)
        let peaks = 72
        var ridge: [SIMD3<Float>] = [], shoulder: [SIMD3<Float>] = [], foot: [SIMD3<Float>] = []
        for i in 0...peaks {
            let x = Float(i) / Float(peaks) * 2 - 1
            let swell = 0.55 + 0.45 * sin(x * 5.3 + 1.1) * sin(x * 2.1)
            let h = (i % 2 == 0 ? 0.35 + 0.65 * r.nextFloat() : 0.15 + 0.4 * r.nextFloat()) * swell
            let back = r.nextFloat()
            ridge.append([x, h, back])
            shoulder.append([x + (r.nextFloat() - 0.5) / Float(peaks), h * (0.35 + 0.3 * r.nextFloat()), back * 0.4])
            foot.append([x, 0, 0])
        }
        for i in 0..<peaks {
            quad(foot[i], foot[i + 1], shoulder[i + 1], shoulder[i], .mountain, normal: [1, 0, 0])
            quad(shoulder[i], shoulder[i + 1], ridge[i + 1], ridge[i], .mountain, normal: [1, 0, 0])
        }
    }
}
