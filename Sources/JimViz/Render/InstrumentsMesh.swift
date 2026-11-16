import simd

/// How a face of the Instruments moves when the shader plays it. `fixed` stays put; a drum
/// (kick, snare, tom) swells and its head pops; the hat's top cymbal lifts; a cymbal rocks on
/// its stand; a bell flares; a key presses in; the slide runs out.
/// Must match the moves in Shaders/generators/lowpoly/instruments.metal.
enum InstrumentMove: Int {
    case fixed, kick, snare, tom, hat, cymbal, bell, key, slide
}

/// Instruments: a jazz band with nobody playing it. A drum kit, a saxophone, a trumpet and a
/// trombone, each built in its own space; the shader sizes, turns and places them.
/// - Drum kit: its front is +x, it stands on a floor at y = -1.
/// - Saxophone: upright in the xy plane, the bell on +x, its keys facing +z.
/// - Trumpet and trombone: along x, the bell at +x.
/// shape: x = the instrument (0 drums, 1 saxophone, 2 trumpet, 3 trombone) + 10 × the face's
/// `InstrumentMove`, y = where along the instrument 0...1 (a horn from its mouthpiece to its
/// bell, the kit from its kick to its cymbals), z = how far this vertex goes with its move
/// (a drum head's middle and a bell's rim 1, a key its travel), w = which one of its kind
/// (cymbal, key). A drum, bell or key moves along its smooth normal.
extension MeshBuilder {
    /// Where the crash and the ride sit on their stands, in the kit's space: they rock about
    /// these. Must match `cymbalPivot` in Shaders/generators/lowpoly/instruments.metal.
    static let cymbalPivots: [SIMD3<Float>] = [[-0.3, 0.72, -0.62], [-0.2, 0.5, 0.98]]

    private struct Part {
        var instrument: Int
        var move = InstrumentMove.fixed
        var index: Float = 0
        var code: Float { Float(instrument + 10 * move.rawValue) }
    }

    private typealias RingVertex = (p: SIMD3<Float>, n: SIMD3<Float>, s: SIMD4<Float>)
    private typealias PipePoint = (p: SIMD3<Float>, r: Float, w: Float)

    mutating func instruments(sides: Int) {
        drumKit(sides: sides)
        saxophone(sides: sides)
        trumpet(sides: sides)
        trombone(sides: sides)
    }

    // MARK: Pieces

    /// Two directions across `axis`, square to it and to each other.
    private static func across(_ axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let u = simd_normalize(simd_cross(axis, abs(axis.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]))
        return (u, simd_cross(axis, u))
    }

    /// `n` points round `centre`, closed (the last is the first again). Their normals point out
    /// from the centre, or all along `normal` for a piece that moves as one.
    private func ring(_ centre: SIMD3<Float>, _ frame: (SIMD3<Float>, SIMD3<Float>), radius: Float, sides n: Int,
                      _ part: Part, along: Float, weight: Float = 0, normal: SIMD3<Float>? = nil) -> [RingVertex] {
        (0...n).map { k in
            let a = Float(k % n) / Float(n) * 2 * .pi
            let d = frame.0 * cos(a) + frame.1 * sin(a)
            return (centre + d * radius, normal ?? d, SIMD4(part.code, along, weight, part.index))
        }
    }

    private mutating func skin(_ a: [RingVertex], _ b: [RingVertex]) {
        for k in 0..<a.count - 1 {
            tri(a[k].p, a[k + 1].p, b[k + 1].p, a[k].n, a[k + 1].n, b[k + 1].n, shape: (a[k].s, a[k + 1].s, b[k + 1].s))
            tri(a[k].p, b[k + 1].p, b[k].p, a[k].n, b[k + 1].n, b[k].n, shape: (a[k].s, b[k + 1].s, b[k].s))
        }
    }

    private mutating func fan(_ a: [RingVertex], to apex: SIMD3<Float>, normal: SIMD3<Float>, weight: Float? = nil) {
        var s = a[0].s
        s.z = weight ?? s.z
        for k in 0..<a.count - 1 {
            tri(a[k].p, a[k + 1].p, apex, a[k].n, a[k + 1].n, normal, shape: (a[k].s, a[k + 1].s, s))
        }
    }

    /// A tube through `points`, each with its radius and weight, `along` running from its first
    /// point to its last. A capped end is closed flat; an open one (a bell) shows its inside.
    private mutating func pipe(_ points: [PipePoint], sides n: Int, _ part: Part, along: (Float, Float),
                               caps: (Bool, Bool) = (true, true), normal: SIMD3<Float>? = nil) {
        var lengths: [Float] = [0]
        for i in 1..<points.count { lengths.append(lengths[i - 1] + simd_distance(points[i].p, points[i - 1].p)) }
        var u = SIMD3<Float>.zero
        var last: [RingVertex] = []
        for i in points.indices {
            let t = simd_normalize(points[min(i + 1, points.count - 1)].p - points[max(i - 1, 0)].p)
            // Carried along the tube, so it doesn't twist.
            u = i == 0 ? MeshBuilder.across(t).0 : simd_normalize(u - t * simd_dot(u, t))
            let at = along.0 + (along.1 - along.0) * lengths[i] / lengths[lengths.count - 1]
            let r = ring(points[i].p, (u, simd_cross(t, u)), radius: points[i].r, sides: n, part,
                         along: at, weight: points[i].w, normal: normal)
            if i > 0 { skin(last, r) }
            if i == 0, caps.0 { fan(r, to: points[i].p, normal: normal ?? -t) }
            if i == points.count - 1, caps.1 { fan(r, to: points[i].p, normal: normal ?? t) }
            last = r
        }
    }

    /// Points round half a circle from `a` to `b`, bulging toward `out`, without the two ends.
    private static func bend(_ a: SIMD3<Float>, _ b: SIMD3<Float>, out: SIMD3<Float>, steps: Int = 3) -> [SIMD3<Float>] {
        let c = (a + b) / 2, half = a - c
        return (1...steps).map { k in
            let angle = Float(k) / Float(steps + 1) * .pi
            return c + half * cos(angle) + simd_normalize(out) * simd_length(half) * sin(angle)
        }
    }

    /// A drum: a shell with a head at each end. The head on the `axis` side pops when it's hit.
    private mutating func drum(_ centre: SIMD3<Float>, axis: SIMD3<Float>, radius: Float, depth: Float,
                               sides n: Int, _ part: Part, along: Float) {
        let a = simd_normalize(axis), frame = MeshBuilder.across(a)
        let top = centre + a * depth / 2, bottom = centre - a * depth / 2
        let rim = ring(top, frame, radius: radius, sides: n, part, along: along)
        let foot = ring(bottom, frame, radius: radius, sides: n, part, along: along)
        let head = ring(top, frame, radius: radius * 0.55, sides: n, part, along: along, weight: 0.6, normal: a)
        skin(foot, rim)
        skin(rim, head)
        fan(head, to: top, normal: a, weight: 1)
        fan(foot, to: bottom, normal: -a)
    }

    /// A cymbal on its `pivot`: a raised bell and a wide, drooping edge. It moves as one, along its axis.
    private mutating func cymbal(_ pivot: SIMD3<Float>, axis: SIMD3<Float>, radius: Float, sides n: Int, _ part: Part, along: Float) {
        let a = simd_normalize(axis), frame = MeshBuilder.across(a)
        let bell = ring(pivot + a * 0.035, frame, radius: radius * 0.22, sides: n, part, along: along, normal: a)
        let edge = ring(pivot - a * 0.02, frame, radius: radius, sides: n, part, along: along, normal: a)
        skin(edge, bell)
        fan(bell, to: pivot + a * 0.07, normal: a)
    }

    // MARK: Drum kit

    private mutating func drumKit(sides n: Int) {
        let round = n * 2, thin = max(n / 2, 3)
        let ground: Float = -1
        func part(_ move: InstrumentMove = .fixed, _ index: Float = 0) -> Part { Part(instrument: 0, move: move, index: index) }
        func rod(_ a: SIMD3<Float>, _ b: SIMD3<Float>, along: Float, radius: Float = 0.018) {
            pipe([(a, radius, 0), (b, radius, 0)], sides: thin, part(), along: (along, along))
        }
        func tripod(_ top: SIMD3<Float>, reach: Float, along: Float) {
            for k in 0..<3 {
                let a = (Float(k) + 0.25) / 3 * 2 * .pi
                rod(top, [top.x + cos(a) * reach, ground, top.z + sin(a) * reach], along: along, radius: 0.014)
            }
        }

        // Kick, on its side facing the front, with a spur each side.
        drum([0, -0.5, 0], axis: [1, 0, 0], radius: 0.5, depth: 0.44, sides: round, part(.kick), along: 0)
        for side: Float in [-1, 1] { rod([0.1, -0.75, 0.42 * side], [0.3, ground, 0.62 * side], along: 0) }

        // Floor tom on three legs.
        let floorTom = SIMD3<Float>(-0.4, -0.45, 0.8)
        drum(floorTom, axis: [0, 1, 0], radius: 0.27, depth: 0.4, sides: round, part(.tom), along: 0.2)
        for k in 0..<3 {
            let a = (Float(k) + 0.5) / 3 * 2 * .pi, d = SIMD3<Float>(cos(a), 0, sin(a))
            rod(floorTom + d * 0.28 + [0, 0.05, 0], [floorTom.x + d.x * 0.36, ground, floorTom.z + d.z * 0.36], along: 0.2, radius: 0.014)
        }

        // Snare on a stand.
        let snare = SIMD3<Float>(-0.5, -0.2, -0.5)
        drum(snare, axis: [0, 1, 0], radius: 0.24, depth: 0.13, sides: round, part(.snare), along: 0.4)
        rod(snare, [snare.x, -0.7, snare.z], along: 0.4)
        tripod([snare.x, -0.7, snare.z], reach: 0.25, along: 0.4)

        // Two rack toms on a post out of the kick, tipped toward the drummer.
        let post = SIMD3<Float>(0, 0.14, 0)
        rod([0, -0.02, 0], post, along: 0.6)
        for (i, side) in [Float(1), -1].enumerated() {
            let centre = SIMD3<Float>(0, 0.27, 0.29 * side)
            drum(centre, axis: [-0.3, 1, 0.1 * side], radius: i == 0 ? 0.22 : 0.2, depth: 0.2, sides: round, part(.tom), along: 0.6)
            rod(post, centre, along: 0.6)
        }

        // Hi-hat: two cymbals rim to rim on a stand. The top one lifts.
        let hat = SIMD3<Float>(-0.3, 0.1, -1)
        rod([hat.x, ground, hat.z], [hat.x, 0.34, hat.z], along: 0.8, radius: 0.012)
        tripod([hat.x, -0.7, hat.z], reach: 0.25, along: 0.8)
        cymbal(hat, axis: [0, -1, 0], radius: 0.25, sides: round, part(), along: 0.8)
        cymbal(hat + [0, 0.04, 0], axis: [0, 1, 0], radius: 0.25, sides: round, part(.hat), along: 0.8)

        // Crash and ride, tipped toward the front, each on a stand.
        for (i, pivot) in MeshBuilder.cymbalPivots.enumerated() {
            let along: Float = i == 0 ? 0.9 : 1
            rod([pivot.x, -0.7, pivot.z], pivot, along: along, radius: 0.014)
            tripod([pivot.x, -0.7, pivot.z], reach: 0.28, along: along)
            cymbal(pivot, axis: [0.3, 1, i == 0 ? 0.1 : -0.1], radius: i == 0 ? 0.34 : 0.4, sides: round, part(.cymbal, Float(i)), along: along)
        }

        // The drummer's stool, empty.
        let stool = SIMD3<Float>(-1, -0.5, 0)
        drum(stool, axis: [0, 1, 0], radius: 0.2, depth: 0.08, sides: round, part(), along: 0)
        rod(stool, [stool.x, -0.75, stool.z], along: 0)
        tripod([stool.x, -0.75, stool.z], reach: 0.22, along: 0)
    }

    // MARK: Saxophone

    private mutating func saxophone(sides n: Int) {
        func part(_ move: InstrumentMove, _ index: Float = 0) -> Part { Part(instrument: 1, move: move, index: index) }
        let bodyTop = SIMD3<Float>(0.01, 0.8, 0), bodyFoot = SIMD3<Float>(0.08, -0.5, 0)
        func body(_ t: Float) -> PipePoint { (bodyTop + (bodyFoot - bodyTop) * t, 0.045 + 0.055 * t, 0) }

        // Mouthpiece, neck, body, the bow at the bottom and the bell coming back up.
        var points: [PipePoint] = [
            ([-0.46, 0.93, 0], 0.022, 0), ([-0.36, 0.98, 0], 0.036, 0), ([-0.27, 1.02, 0], 0.03, 0),
            ([-0.15, 1.04, 0], 0.028, 0), ([-0.05, 1, 0], 0.032, 0), ([0, 0.9, 0], 0.038, 0),
            body(0), body(0.5), body(1),
        ]
        let bow = MeshBuilder.bend(bodyFoot, [0.52, -0.5, 0], out: [0, -1, 0])
        for (i, p) in bow.enumerated() { points.append((p, 0.105 + 0.006 * Float(i), 0)) }
        points += [([0.52, -0.5, 0], 0.125, 0), ([0.56, -0.2, 0], 0.14, 0.15), ([0.6, 0.02, 0], 0.17, 0.4),
                   ([0.65, 0.14, 0], 0.23, 0.75), ([0.69, 0.2, 0], 0.31, 1)]
        pipe(points, sides: n, part(.bell), along: (0, 1), caps: (true, false))

        // Key cups down the body and two on the bell, each on a short stem, facing +z.
        let out = SIMD3<Float>(0, 0, 1)
        var keys: [(centre: SIMD3<Float>, tube: Float, radius: Float, along: Float)] = ([0.12, 0.26, 0.4, 0.56, 0.72, 0.88] as [Float]).map { t in
            let b = body(t)
            return (b.p, b.r, 0.04 + 0.02 * t, 0.2 + 0.3 * t)
        }
        keys += [([0.54, -0.36, 0], 0.132, 0.07, 0.7), ([0.585, -0.08, 0], 0.158, 0.08, 0.8)]
        for (i, key) in keys.enumerated() {
            let cup = key.centre + out * (key.tube + 0.04), travel: Float = 0.035, p = part(.key, Float(i))
            pipe([(cup - out * 0.008, key.radius, travel), (cup + out * 0.008, key.radius, travel)],
                 sides: n, p, along: (key.along, key.along), normal: out)
            pipe([(key.centre, 0.012, travel), (cup, 0.012, travel)], sides: 3, p, along: (key.along, key.along),
                 caps: (false, false), normal: out)
        }
    }

    // MARK: Trumpet

    private mutating func trumpet(sides n: Int) {
        func part(_ move: InstrumentMove, _ index: Float = 0) -> Part { Part(instrument: 2, move: move, index: index) }
        let tube: Float = 0.026

        // Mouthpiece, the leadpipe forward, round the front bend, back under the valves, round
        // the back bend and forward again into the bell.
        var points: [PipePoint] = [
            ([-0.95, 0.1, 0.06], 0.05, 0), ([-0.92, 0.1, 0.06], 0.045, 0), ([-0.86, 0.1, 0.06], 0.018, 0),
            ([-0.8, 0.1, 0.06], tube, 0), ([0.3, 0.1, 0.06], tube, 0),
        ]
        points += MeshBuilder.bend([0.3, 0.1, 0.06], [0.3, -0.1, 0], out: [1, 0, 0]).map { ($0, tube, 0) }
        points += [([0.3, -0.1, 0], tube, 0), ([-0.35, -0.1, 0], tube, 0)]
        points += MeshBuilder.bend([-0.35, -0.1, 0], [-0.35, 0.1, -0.06], out: [-1, 0, 0]).map { ($0, tube + 0.002, 0) }
        points += [([-0.35, 0.1, -0.06], 0.03, 0), ([0, 0.1, -0.06], 0.034, 0), ([0.45, 0.1, -0.06], 0.045, 0),
                   ([0.62, 0.1, -0.06], 0.065, 0.2), ([0.76, 0.1, -0.06], 0.1, 0.45), ([0.86, 0.1, -0.06], 0.16, 0.7),
                   ([0.92, 0.1, -0.06], 0.24, 0.9), ([0.95, 0.1, -0.06], 0.31, 1)]
        pipe(points, sides: n, part(.bell), along: (0, 1), caps: (true, false))

        // Three valves: a casing each, and a piston with a button on top that presses down.
        let up = SIMD3<Float>(0, 1, 0)
        for i in 0..<3 {
            let x = Float(i - 1) * 0.12, travel: Float = 0.08, p = part(.key, Float(i))
            pipe([([x, -0.24, 0], 0.045, 0), ([x, 0.2, 0], 0.045, 0)], sides: n, part(.fixed), along: (0.5, 0.5))
            pipe([([x, 0.1, 0], 0.012, travel), ([x, 0.3, 0], 0.012, travel)], sides: 3, p, along: (0.5, 0.5),
                 caps: (false, false), normal: up)
            pipe([([x, 0.3, 0], 0.04, travel), ([x, 0.325, 0], 0.04, travel)], sides: n, p, along: (0.5, 0.5), normal: up)
        }
    }

    // MARK: Trombone

    private mutating func trombone(sides n: Int) {
        func part(_ move: InstrumentMove) -> Part { Part(instrument: 3, move: move) }
        let thin = max(n / 2, 3)

        // Mouthpiece and the upper inner slide tube.
        pipe([([-0.62, 0.07, 0.1], 0.05, 0), ([-0.59, 0.07, 0.1], 0.045, 0), ([-0.53, 0.07, 0.1], 0.018, 0),
              ([-0.47, 0.07, 0.1], 0.022, 0), ([0.8, 0.07, 0.1], 0.022, 0)], sides: n, part(.fixed), along: (0, 0.25))

        // The slide: the outer tubes and the crook at their far end, with a brace to hold. It runs out along +x.
        var slide: [PipePoint] = [([0, 0.07, 0.1], 0.03, 1), ([0.9, 0.07, 0.1], 0.03, 1)]
        slide += MeshBuilder.bend([0.9, 0.07, 0.1], [0.9, -0.07, 0.1], out: [1, 0, 0]).map { ($0, 0.03, 1) }
        slide += [([0.9, -0.07, 0.1], 0.03, 1), ([0, -0.07, 0.1], 0.03, 1)]
        pipe(slide, sides: n, part(.slide), along: (0.25, 0.5))
        pipe([([0.06, 0.07, 0.1], 0.015, 1), ([0.06, -0.07, 0.1], 0.015, 1)], sides: thin, part(.slide), along: (0.25, 0.25))

        // The lower inner tube back past the mouthpiece, round the tuning bend and forward into the bell.
        let back = SIMD3<Float>(-0.75, -0.07, 0.1), over = SIMD3<Float>(-0.75, 0, -0.26)
        var points: [PipePoint] = [([0.8, -0.07, 0.1], 0.022, 0), ([-0.45, -0.07, 0.1], 0.024, 0), (back, 0.026, 0)]
        points += MeshBuilder.bend(back, over, out: [-1, 0, 0]).map { ($0, 0.028, 0) }
        points += [(over, 0.03, 0), ([-0.3, 0, -0.26], 0.034, 0), ([0.15, 0, -0.26], 0.05, 0),
                   ([0.35, 0, -0.26], 0.075, 0.2), ([0.5, 0, -0.26], 0.12, 0.45), ([0.6, 0, -0.26], 0.18, 0.7),
                   ([0.66, 0, -0.26], 0.25, 0.9), ([0.69, 0, -0.26], 0.3, 1)]
        pipe(points, sides: n, part(.bell), along: (0.5, 1), caps: (true, false))

        // Braces: between the inner tubes, and across to the bell.
        for (a, b) in [(SIMD3<Float>(-0.35, 0.07, 0.1), SIMD3<Float>(-0.35, -0.07, 0.1)), ([-0.35, 0.07, 0.1], [-0.35, 0, -0.26])] {
            pipe([(a, 0.015, 0), (b, 0.015, 0)], sides: thin, part(.fixed), along: (0.5, 0.5))
        }
    }
}
