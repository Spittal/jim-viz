import simd

/// Street: an endless street lined with buildings. The mesh holds the street once and one of each
/// building style; the shader draws it instanced, one instance per lot (two sides × the lots
/// that fit along the street) plus instance 0 for the street, and each lot keeps only the style
/// it picks. Which part a face is sits in shape.w (`StreetPart`), its style in shape.y
/// (`StreetStyle`, `streetStyle` for the street, `lampStyle` for the lamp post).
/// - street (road, curb, sidewalk, ground): position.x = distance along the street 0...1 before
///   it scrolls, position.y = up the curb 0...1, position.z = across (road -1...1, the rest
///   0...1 out from the road's edge), shape.x = side (-1 left, 1 right).
/// - building: position = (u along the lot -0.5...0.5, h up the building's height 0...1,
///   w back from its front 0...1), shape.x = height above h in units of the building's width
///   (roofs, spires, domes keep their proportions however tall the building is), shape.z =
///   how far the slab turns with twist 0...1 (the Twisted tower; 0 elsewhere).
/// - lamp: position = metres from the foot of the post (along, up, back from the curb).
/// Must match the constants in Shaders/generators/lowpoly/street.metal.
enum StreetPart: Int {
    case road, curb, sidewalk, ground, wall, roof, trim, glass, accent, dark, post, lamp
}

enum StreetStyle: Int, CaseIterable {
    case blocks, deco, townhouse, tenement, pagoda, dome, brutalist, twisted, warehouse, crystal, gothic
    static let streetStyle: Float = -1
    static let lampStyle = Float(allCases.count)
}

/// How many lots fit along a street `distance` ahead and `behind` back, `lot` apart. The shader's
/// `streetLots` must match.
func streetLots(distance: Float, behind: Float, lot: Float) -> Int {
    min(max(Int(((distance + behind) / max(lot, 1) - 0.01).rounded(.up)), 1), 128)
}

extension MeshBuilder {
    mutating func street(segments: Int, detail: Int) {
        var street = StreetKit(style: StreetStyle.streetStyle)
        street.strips(segments)
        vertices += street.vertices
        for style in StreetStyle.allCases {
            var kit = StreetKit(style: Float(style.rawValue))
            kit.building(style, detail: detail)
            vertices += kit.vertices
        }
        var lamp = StreetKit(style: StreetStyle.lampStyle)
        lamp.lamp()
        vertices += lamp.vertices
    }
}

/// A height on a building: h up its height 0...1, then e more in units of its width.
private struct Y {
    var h: Float, e: Float
    init(_ h: Float, _ e: Float = 0) { self.h = h; self.e = e }
}

/// Builds one style's faces. Points are (u, h, w, e); see `StreetPart`.
private struct StreetKit {
    var vertices: [MeshVertex] = []
    let style: Float
    /// How far the faces being built turn with twist.
    var twist: Float = 0
    private var rng = SplitMix(seed: 0x57EE7)

    init(style: Float) { self.style = style }

    static func v(_ u: Float, _ y: Y, _ w: Float) -> SIMD4<Float> { [u, y.h, w, y.e] }

    /// Where a point sits in a typical building (as wide as deep, twice as tall), for normals.
    private static func proxy(_ p: SIMD4<Float>) -> SIMD3<Float> { [p.x, p.y * 2 + p.w, p.z] }

    mutating func tri(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ c: SIMD4<Float>, _ part: StreetPart) {
        let pa = Self.proxy(a), pb = Self.proxy(b), pc = Self.proxy(c)
        var n = simd_normalize(simd_cross(pb - pa, pc - pa))
        if !n.x.isFinite { n = [0, 1, 0] }
        // Outward, away from the middle of a typical building.
        if simd_dot(n, (pa + pb + pc) / 3 - [0, 1, 0.5]) < 0 { n = -n }
        let r = rng.nextFloat()
        let bary: [SIMD4<Float>] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
        for (i, p) in [a, b, c].enumerated() {
            vertices.append(MeshVertex(position: [p.x, p.y, p.z, r], faceNormal: SIMD4(n, 0), smoothNormal: SIMD4(n, 0),
                                       bary: bary[i], shape: [p.w, style, twist, Float(part.rawValue)]))
        }
    }

    mutating func quad(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ c: SIMD4<Float>, _ d: SIMD4<Float>, _ part: StreetPart) {
        tri(a, b, c, part)
        tri(a, c, d, part)
    }

    /// A box over u0...u1 and w0...w1 from y0 to y1. No top when `top` is nil; a bottom when
    /// it floats (a cantilever or a ledge).
    mutating func box(_ u0: Float, _ u1: Float, _ w0: Float, _ w1: Float, _ y0: Y, _ y1: Y,
                      side: StreetPart = .wall, top: StreetPart? = .roof, bottom: Bool = false) {
        frustum([u0, u1, w0, w1], y0, [u0, u1, w0, w1], y1, side: side, top: top)
        if bottom {
            let v = Self.v
            quad(v(u0, y0, w0), v(u1, y0, w0), v(u1, y0, w1), v(u0, y0, w1), side == .wall ? .dark : side)
        }
    }

    /// Four sides from rectangle r0 (u0, u1, w0, w1) at y0 up to r1 at y1, and a cap on r1.
    mutating func frustum(_ r0: SIMD4<Float>, _ y0: Y, _ r1: SIMD4<Float>, _ y1: Y, side: StreetPart, top: StreetPart?) {
        let v = Self.v
        let a = [v(r0.x, y0, r0.z), v(r0.y, y0, r0.z), v(r0.y, y0, r0.w), v(r0.x, y0, r0.w)]
        let b = [v(r1.x, y1, r1.z), v(r1.y, y1, r1.z), v(r1.y, y1, r1.w), v(r1.x, y1, r1.w)]
        for k in 0..<4 { quad(a[k], a[(k + 1) % 4], b[(k + 1) % 4], b[k], side) }
        if let top { quad(b[0], b[1], b[2], b[3], top) }
    }

    /// A four-sided pyramid on rectangle r at y up to its centre at apex.
    mutating func pyramid(_ r: SIMD4<Float>, _ y: Y, apex: Y, _ part: StreetPart) {
        let cu = (r.x + r.y) / 2, cw = (r.z + r.w) / 2
        frustum(r, y, [cu, cu, cw, cw], apex, side: part, top: nil)
    }

    /// A pitched roof on u0...u1, w0...w1 at y, rising `rise` widths. Along: the ridge runs along
    /// the street; otherwise it runs back, so the gable end faces the street.
    mutating func gable(_ u0: Float, _ u1: Float, _ w0: Float, _ w1: Float, _ y: Y, rise: Float, along: Bool,
                        roof: StreetPart = .roof, end: StreetPart = .wall) {
        let v = Self.v, top = Y(y.h, y.e + rise)
        if along {
            let wm = (w0 + w1) / 2
            quad(v(u0, y, w0), v(u1, y, w0), v(u1, top, wm), v(u0, top, wm), roof)
            quad(v(u0, y, w1), v(u1, y, w1), v(u1, top, wm), v(u0, top, wm), roof)
            tri(v(u0, y, w0), v(u0, y, w1), v(u0, top, wm), end)
            tri(v(u1, y, w0), v(u1, y, w1), v(u1, top, wm), end)
        } else {
            let um = (u0 + u1) / 2
            quad(v(u0, y, w0), v(u0, y, w1), v(um, top, w1), v(um, top, w0), roof)
            quad(v(u1, y, w0), v(u1, y, w1), v(um, top, w1), v(um, top, w0), roof)
            tri(v(u0, y, w0), v(u1, y, w0), v(um, top, w0), end)
            tri(v(u0, y, w1), v(u1, y, w1), v(um, top, w1), end)
        }
    }

    /// A prism of `sides` sides round (cu, cw) through rings of radius r (on u and w) at y,
    /// each turned by `turn` of a side. A last ring of radius 0 closes it to a point; otherwise
    /// `cap` closes the top.
    mutating func loft(_ cu: Float, _ cw: Float, _ rings: [(r: Float, y: Y, turn: Float)], sides: Int,
                       _ part: StreetPart, cap: StreetPart? = nil) {
        func p(_ ring: (r: Float, y: Y, turn: Float), _ k: Int) -> SIMD4<Float> {
            let a = (Float(k) + ring.turn) / Float(sides) * 2 * .pi
            return Self.v(cu + cos(a) * ring.r, ring.y, cw + sin(a) * ring.r)
        }
        for j in 0..<rings.count - 1 {
            for k in 0..<sides {
                let a = p(rings[j], k), b = p(rings[j], k + 1), c = p(rings[j + 1], k + 1), d = p(rings[j + 1], k)
                if rings[j + 1].r == 0 { tri(a, b, c, part) } else { quad(a, b, c, d, part) }
            }
        }
        if let cap, let last = rings.last, last.r > 0 {
            let centre = Self.v(cu, last.y, cw)
            for k in 0..<sides { tri(centre, p(last, k), p(last, k + 1), cap) }
        }
    }

    // MARK: - The street

    /// One strip of faces per segment: the road, a curb and sidewalk each side, and the ground
    /// out behind the buildings in columns that widen going out.
    mutating func strips(_ segments: Int) {
        let columns: [Float] = [0, 0.1, 0.25, 0.5, 1]
        for i in 0..<segments {
            let x0 = Float(i) / Float(segments), x1 = Float(i + 1) / Float(segments)
            func strip(_ part: StreetPart, _ side: Float, _ z0: Float, _ z1: Float, up: Bool = false) {
                let s = SIMD4<Float>(side, style, 0, Float(part.rawValue))
                let pts: [SIMD3<Float>] = up ? [[x0, 0, 0], [x1, 0, 0], [x1, 1, 0], [x0, 1, 0]]
                                             : [[x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1]]
                let n: SIMD3<Float> = up ? [0, 0, -side] : [0, 1, 0]
                for (a, b, c) in [(0, 1, 2), (0, 2, 3)] {
                    let r = rng.nextFloat()
                    for (k, j) in [a, b, c].enumerated() {
                        var bary = SIMD4<Float>.zero
                        bary[k] = 1
                        vertices.append(MeshVertex(position: SIMD4(pts[j], r), faceNormal: SIMD4(n, 0),
                                                   smoothNormal: SIMD4(n, 0), bary: bary, shape: s))
                    }
                }
            }
            strip(.road, 0, -1, 1)
            for side: Float in [-1, 1] {
                strip(.curb, side, 0, 0, up: true)
                strip(.sidewalk, side, 0, 1)
                for k in 0..<columns.count - 1 { strip(.ground, side, columns[k], columns[k + 1]) }
            }
        }
    }

    /// A street lamp in metres: a post at the curb, an arm out over the road, a glowing head.
    mutating func lamp() {
        box(-0.09, 0.09, -0.09, 0.09, Y(0), Y(0.5), side: .post, top: nil)
        box(-0.06, 0.06, -0.06, 0.06, Y(0.5), Y(5.0), side: .post, top: .post)
        box(-0.05, 0.05, -1.5, -0.06, Y(4.85), Y(5.0), side: .post, top: .post, bottom: true)
        box(-0.3, 0.3, -1.75, -1.15, Y(4.75), Y(4.92), side: .post, top: .post)
        box(-0.24, 0.24, -1.69, -1.21, Y(4.62), Y(4.75), side: .lamp, top: nil, bottom: true)
    }

    // MARK: - Buildings

    /// A lot's building in one style. detail 0 is the bare massing, 1 adds rooftop clutter
    /// (plant rooms, water towers, chimneys, pinnacles), 2 adds trims (cornices, fins, fire
    /// escapes, columns, rose windows).
    mutating func building(_ style: StreetStyle, detail d: Int) {
        let v = Self.v
        switch style {
        case .blocks:
            box(-0.5, 0.5, 0, 1, Y(0), Y(1))
            if d >= 1 {
                box(-0.25, 0.12, 0.35, 0.8, Y(1), Y(1, 0.07), side: .trim)
                box(0.2, 0.35, 0.2, 0.4, Y(1), Y(1, 0.04), side: .trim)
                box(-0.012, 0.012, 0.55, 0.57, Y(1, 0.07), Y(1, 0.45), side: .accent, top: .accent)
            }
            if d >= 2 {
                for (u0, u1, w0, w1) in [(-0.5, 0.5, 0, 0.02), (-0.5, 0.5, 0.98, 1), (-0.5, -0.48, 0, 1), (0.48, 0.5, 0, 1)] as [(Float, Float, Float, Float)] {
                    box(u0, u1, w0, w1, Y(1), Y(1, 0.025), side: .trim, top: .trim)
                }
                box(-0.35, 0.35, -0.12, 0, Y(0, 0.2), Y(0, 0.215), side: .trim, top: .trim, bottom: true)
            }

        case .deco:
            box(-0.5, 0.5, 0, 1, Y(0), Y(0.6))
            box(-0.38, 0.38, 0.12, 0.88, Y(0.6), Y(0.82))
            box(-0.25, 0.25, 0.25, 0.75, Y(0.82), Y(1))
            frustum([-0.14, 0.14, 0.36, 0.64], Y(1), [-0.08, 0.08, 0.42, 0.58], Y(1, 0.12), side: .accent, top: nil)
            pyramid([-0.08, 0.08, 0.42, 0.58], Y(1, 0.12), apex: Y(1, 0.75), .accent)
            if d >= 1 {
                for (u, w) in [(-0.44, 0.06), (0.44, 0.06), (-0.44, 0.94), (0.44, 0.94)] as [(Float, Float)] {
                    pyramid([u - 0.04, u + 0.04, w - 0.04, w + 0.04], Y(0.6), apex: Y(0.6, 0.12), .accent)
                }
            }
            if d >= 2 {
                for u: Float in [-0.3, -0.1, 0.1, 0.3] {
                    box(u - 0.012, u + 0.012, -0.03, 0, Y(0.04), Y(0.6), side: .trim, top: .trim)
                }
                box(-0.51, 0.51, -0.01, 1.01, Y(0.6), Y(0.6, 0.012), side: .trim, top: .trim, bottom: true)
                box(-0.39, 0.39, 0.11, 0.89, Y(0.82), Y(0.82, 0.012), side: .trim, top: .trim, bottom: true)
            }

        case .townhouse:
            // Three narrow houses sharing the lot, each its own height under a pitched roof.
            let houses: [(u0: Float, u1: Float, h: Float, rise: Float)] = [(-0.5, -0.18, 0.85, 0.16), (-0.18, 0.17, 1, 0.2), (0.17, 0.5, 0.75, 0.14)]
            for house in houses {
                box(house.u0, house.u1, 0, 0.8, Y(0), Y(house.h), top: nil)
                gable(house.u0 - 0.005, house.u1 + 0.005, -0.03, 0.83, Y(house.h), rise: house.rise, along: true)
                if d >= 1 {
                    box(house.u1 - 0.09, house.u1 - 0.04, 0.5, 0.58, Y(house.h), Y(house.h, house.rise + 0.06), side: .trim, top: .dark)
                }
                if d >= 2 {
                    let um = (house.u0 + house.u1) / 2
                    quad(v(um - 0.045, Y(0, 0.03), -0.004), v(um + 0.045, Y(0, 0.03), -0.004),
                         v(um + 0.045, Y(0, 0.17), -0.004), v(um - 0.045, Y(0, 0.17), -0.004), .dark)
                    box(um - 0.07, um + 0.07, -0.1, 0, Y(0), Y(0, 0.03), side: .trim, top: .trim)
                    box(house.u0, house.u1, -0.025, 0.81, Y(house.h, -0.015), Y(house.h), side: .trim, top: nil, bottom: true)
                }
            }

        case .tenement:
            box(-0.5, 0.5, 0, 1, Y(0), Y(1))
            box(-0.52, 0.52, -0.05, 1, Y(1), Y(1, 0.05), side: .trim, top: .roof, bottom: true)
            box(-0.505, 0.505, -0.012, 1, Y(0), Y(0, 0.18), side: .trim, top: .trim)
            if d >= 1 {
                // Water tower on four legs.
                let cu: Float = 0.2, cw: Float = 0.62
                for (du, dw) in [(-0.05, -0.05), (0.05, -0.05), (0.05, 0.05), (-0.05, 0.05)] as [(Float, Float)] {
                    box(cu + du - 0.008, cu + du + 0.008, cw + dw - 0.008, cw + dw + 0.008, Y(1, 0.05), Y(1, 0.14), side: .dark, top: nil)
                }
                loft(cu, cw, [(0.075, Y(1, 0.14), 0), (0.075, Y(1, 0.26), 0), (0.082, Y(1, 0.265), 0), (0, Y(1, 0.33), 0)], sides: 8, .trim)
            }
            if d >= 2 {
                // Fire escape: a landing and a rail each floor or so.
                for k in 1...4 {
                    let h = Float(k) * 0.2
                    box(-0.22, 0.22, -0.08, 0, Y(h), Y(h, 0.006), side: .dark, top: .dark, bottom: true)
                    box(-0.22, 0.22, -0.08, -0.074, Y(h, 0.006), Y(h, 0.03), side: .dark, top: .dark)
                }
            }

        case .pagoda:
            for k in 0..<4 {
                let i = Float(k) * 0.07, t0 = Float(k) / 4, t1 = Float(k + 1) / 4
                box(-0.38 + i, 0.38 - i, 0.12 + i, 0.88 - i, Y(t0), Y(t1), top: nil)
                // A flared hip roof, wider than the tier, its eaves underneath dark.
                let eave: SIMD4<Float> = [-0.49 + i, 0.49 - i, 0.01 + i, 0.99 - i]
                frustum(eave, Y(t1), [-0.3 + i, 0.3 - i, 0.2 + i, 0.8 - i], Y(t1, 0.07), side: .roof, top: .roof)
                quad(v(eave.x, Y(t1), eave.z), v(eave.y, Y(t1), eave.z), v(eave.y, Y(t1), eave.w), v(eave.x, Y(t1), eave.w), .dark)
            }
            loft(0, 0.5, [(0.02, Y(1, 0.07), 0), (0.02, Y(1, 0.35), 0), (0, Y(1, 0.45), 0)], sides: 6, .accent)
            if d >= 1 {
                for k in 0..<4 {
                    let h = Float(k + 1) / 4, i = Float(k) * 0.07
                    for (u, w) in [(-0.49 + i, 0.01 + i), (0.49 - i, 0.01 + i), (0.49 - i, 0.99 - i), (-0.49 + i, 0.99 - i)] {
                        pyramid([u - 0.015, u + 0.015, w - 0.015, w + 0.015], Y(h), apex: Y(h, 0.06), .accent)
                    }
                }
            }
            if d >= 2 {
                for h: Float in [0.08, 0.16, 0.24, 0.32] {
                    loft(0, 0.5, [(0.045, Y(1, h), 0), (0.045, Y(1, h + 0.012), 0)], sides: 6, .accent, cap: .accent)
                }
            }

        case .dome:
            box(-0.5, 0.5, 0.15, 1, Y(0), Y(0.6))
            box(-0.36, 0.36, -0.12, 0.15, Y(0), Y(0, 0.03), side: .trim, top: .trim)
            box(-0.33, 0.33, -0.06, 0.15, Y(0.5), Y(0.55), side: .trim, top: nil, bottom: true)
            gable(-0.33, 0.33, -0.06, 0.15, Y(0.55), rise: 0.08, along: false, roof: .roof, end: .trim)
            for k in 0..<6 {
                let u = -0.27 + Float(k) * 0.108
                loft(u, 0.0, [(0.025, Y(0, 0.03), 0), (0.025, Y(0.5), 0)], sides: 6, .trim)
            }
            // A drum and a faceted dome, a lantern on top.
            let drum: Float = 0.24
            loft(0, 0.575, [(drum, Y(0.6), 0.5), (drum, Y(0.6, 0.1), 0.5)], sides: 8, .wall)
            var dome: [(r: Float, y: Y, turn: Float)] = []
            for k in 0...3 {
                let a = Float(k) / 4 * .pi / 2
                dome.append((drum * cos(a) * 1.04, Y(0.6, 0.1 + 0.22 * sin(a)), 0.5))
            }
            dome.append((0, Y(0.6, 0.33), 0.5))
            loft(0, 0.575, dome, sides: 8, .roof)
            loft(0, 0.575, [(0.03, Y(0.6, 0.31), 0), (0.03, Y(0.6, 0.38), 0), (0, Y(0.6, 0.44), 0)], sides: 6, .accent)
            if d >= 1 {
                for u: Float in [-0.45, 0.45] {
                    loft(u, 0.2, [(0.04, Y(0.6), 0), (0.04, Y(0.6, 0.05), 0), (0, Y(0.6, 0.1), 0)], sides: 4, .accent)
                }
            }
            if d >= 2 {
                loft(0, 0.575, [(drum * 1.08, Y(0.6, 0.1), 0.5), (drum * 1.08, Y(0.6, 0.115), 0.5)], sides: 8, .trim, cap: .trim)
                box(-0.51, 0.51, 0.14, 1.01, Y(0.6), Y(0.6, 0.02), side: .trim, top: .trim, bottom: true)
            }

        case .brutalist:
            let blocks: [(u0: Float, u1: Float, w0: Float, w1: Float, h0: Float, h1: Float)] = [
                (-0.5, 0.3, 0, 0.8, 0, 0.3), (-0.3, 0.5, -0.15, 0.7, 0.3, 0.55),
                (-0.5, 0.2, 0.1, 1, 0.55, 0.8), (-0.2, 0.45, -0.1, 0.6, 0.8, 1),
            ]
            for b in blocks { box(b.u0, b.u1, b.w0, b.w1, Y(b.h0), Y(b.h1), bottom: b.h0 > 0) }
            if d >= 1 {
                box(0.3, 0.45, 0.75, 0.95, Y(0), Y(1, 0.08))
                box(-0.45, -0.3, 0.3, 0.5, Y(0.8), Y(0.8, 0.05), side: .trim)
            }
            if d >= 2 {
                for k in 0...8 {
                    let u = -0.3 + Float(k) * 0.1
                    box(u - 0.008, u + 0.008, -0.19, -0.15, Y(0.3), Y(0.55), side: .trim, top: .trim)
                }
            }

        case .twisted:
            let floors = 10
            for k in 0..<floors {
                let t0 = Float(k) / Float(floors), t1 = Float(k + 1) / Float(floors)
                twist = (t0 + t1) / 2
                box(-0.32, 0.32, 0.18, 0.82, Y(t0), Y(t1, -0.012), side: .glass, top: .roof, bottom: k > 0)
                if d >= 2 {
                    box(-0.345, 0.345, 0.155, 0.845, Y(t1, -0.012), Y(t1), side: .trim, top: .trim, bottom: true)
                }
            }
            twist = 1
            pyramid([-0.32, 0.32, 0.18, 0.82], Y(1), apex: Y(1, 0.3), .accent)
            if d >= 1 { box(-0.008, 0.008, 0.49, 0.51, Y(1, 0.28), Y(1, 0.55), side: .accent, top: .accent) }
            twist = 0

        case .warehouse:
            box(-0.5, 0.5, 0, 1, Y(0), Y(1), top: nil)
            // Sawtooth roof: slopes facing back, glazing facing the street.
            for k in 0..<4 {
                let w0 = Float(k) / 4, w1 = Float(k + 1) / 4
                let low = Y(1), high = Y(1, 0.1)
                quad(v(-0.5, high, w0), v(0.5, high, w0), v(0.5, low, w1), v(-0.5, low, w1), .roof)
                quad(v(-0.5, low, w0), v(0.5, low, w0), v(0.5, high, w0), v(-0.5, high, w0), .glass)
                tri(v(-0.5, low, w0), v(-0.5, high, w0), v(-0.5, low, w1), .wall)
                tri(v(0.5, low, w0), v(0.5, high, w0), v(0.5, low, w1), .wall)
            }
            if d >= 1 {
                for (u0, u1) in [(-0.38, -0.08), (0.08, 0.38)] as [(Float, Float)] {
                    quad(v(u0, Y(0), -0.004), v(u1, Y(0), -0.004), v(u1, Y(0, 0.22), -0.004), v(u0, Y(0, 0.22), -0.004), .dark)
                }
            }
            if d >= 2 {
                loft(0.38, 0.85, [(0.04, Y(1), 0), (0.035, Y(1, 0.55), 0), (0.04, Y(1, 0.56), 0), (0.04, Y(1, 0.6), 0)],
                     sides: 8, .trim, cap: .dark)
                loft(0.38, 0.85, [(0.037, Y(1, 0.45), 0), (0.037, Y(1, 0.48), 0)], sides: 8, .accent)
            }

        case .crystal:
            loft(0, 0.5, [(0.48, Y(0), 0), (0.44, Y(0.35), 0.3), (0.36, Y(0.7), 0.6), (0.22, Y(1), 0.9), (0, Y(1, 0.4), 1.2)],
                 sides: 6, .glass)
            if d >= 1 {
                for (u, w) in [(-0.4, 0.12), (0.4, 0.12)] as [(Float, Float)] {
                    loft(u, w, [(0.1, Y(0), 0), (0, Y(0.3), 0.5)], sides: 3, .glass)
                }
            }
            if d >= 2 {
                for (r, h, turn) in [(0.45, 0.35, 0.3), (0.375, 0.7, 0.6)] as [(Float, Float, Float)] {
                    loft(0, 0.5, [(r, Y(h), turn), (r, Y(h, 0.012), turn)], sides: 6, .accent)
                }
            }

        case .gothic:
            box(-0.3, 0.3, 0.15, 1, Y(0), Y(0.7), top: nil)
            gable(-0.31, 0.31, 0.14, 1.01, Y(0.7), rise: 0.35, along: false)
            for s: Float in [-1, 1] {
                let u0: Float = s < 0 ? -0.5 : 0.3, u1: Float = s < 0 ? -0.3 : 0.5
                box(u0, u1, 0, 0.25, Y(0), Y(1))
                pyramid([u0, u1, 0, 0.25], Y(1), apex: Y(1, 0.6), .accent)
                if d >= 1 {
                    for (u, w) in [(u0, 0), (u1, 0), (u1, 0.25), (u0, 0.25)] as [(Float, Float)] {
                        pyramid([u - 0.018, u + 0.018, w - 0.018, w + 0.018], Y(1), apex: Y(1, 0.12), .accent)
                    }
                }
            }
            if d >= 1 {
                for w: Float in [0.4, 0.6, 0.8] {
                    for u: Float in [-0.34, 0.3] {
                        box(u, u + 0.04, w - 0.03, w + 0.03, Y(0), Y(0.5), side: .trim, top: nil)
                        frustum([u, u + 0.04, w - 0.03, w + 0.03], Y(0.5), [u + (u < 0 ? 0.04 : 0), u + (u < 0 ? 0.04 : 0), w - 0.03, w + 0.03],
                                Y(0.7), side: .trim, top: nil)
                    }
                }
            }
            if d >= 2 {
                // Rose window over the door, and the door.
                let centre = v(0, Y(0.5), 0.146)
                for k in 0..<8 {
                    let a0 = Float(k) / 8 * 2 * .pi, a1 = Float(k + 1) / 8 * 2 * .pi
                    tri(centre, v(cos(a0) * 0.13, Y(0.5, sin(a0) * 0.13), 0.146), v(cos(a1) * 0.13, Y(0.5, sin(a1) * 0.13), 0.146), .accent)
                }
                quad(v(-0.08, Y(0), 0.146), v(0.08, Y(0), 0.146), v(0.08, Y(0.2), 0.146), v(-0.08, Y(0.2), 0.146), .dark)
                tri(v(-0.08, Y(0.2), 0.146), v(0.08, Y(0.2), 0.146), v(0, Y(0.2, 0.08), 0.146), .dark)
            }
        }
    }
}
