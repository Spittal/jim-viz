import Metal
import simd

/// Jenga's sizes, in the geo's own units (before `scale`). Must match the constants in
/// Shaders/generators/simulation/jenga.metal.
enum JengaLayout {
    /// A block: long along its x, `width` across, `height` tall. Three side by side make a square layer.
    static let length: Float = 0.75, height: Float = 0.15, width: Float = 0.25
    /// The plinth the tower stands on: its top, and its radius there. The ground is below it.
    static let plinthTop: Float = -1.0, plinthRadius: Float = 0.85, ground: Float = -1.3
    static let terrainRadius: Float = 6
    static let maxLayers = 24
    /// Blocks in the mesh: a full tower, the one in the hand, and room for fallen ones fading out.
    static let maxBodies = 96
    /// float4 offsets in JengaSim's buffer.
    static let handOffset = 1, bodyOffset = 3

    /// Where block `slot` (0...2) of layer `layer` sits on a still plinth, and its turn about y.
    /// Even layers run along x, side by side along z; odd layers along z, side by side along x.
    static func home(_ layer: Int, _ slot: Int) -> (pos: SIMD3<Float>, yaw: Float) {
        let y = plinthTop + (Float(layer) + 0.5) * height, off = Float(slot - 1) * width
        return layer % 2 == 0 ? ([0, y, off], 0) : ([off, y, 0], .pi / 2)
    }
}

/// What a Jenga vertex belongs to, in shape.x. The hand's vertices keep `MeshBuilder.hand`'s own
/// codes, which are 0 and up. Must match jenga.metal.
enum JengaPart: Float {
    case terrain = -1, plinth = -2, block = -3
}

extension MeshBuilder {
    /// Jenga: the ground, the plinth, `JengaLayout.maxBodies` blocks and a hand whose fingers
    /// are `sides`-sided tubes. JengaSim places the blocks and the hand.
    /// Ground: a disc of jittered rings; position xz in units, shape.y how far out 0...1.
    /// Plinth: an eight-sided slab, position from the centre of its top.
    /// Blocks: a unit box, -0.5...0.5, long along x; shape.y = which block.
    /// Hand: as `hand`, segments 2, shape.x 0 and up.
    mutating func jenga(sides: Int) {
        let up = SIMD3<Float>(0, 1, 0)

        // The ground, from under the plinth out to the edge.
        let rings = 18, segs = 56
        var r = SplitMix(seed: 0x7E46A)
        var pts: [[SIMD3<Float>]] = []
        for i in 0...rings {
            let t = Float(i) / Float(rings)
            let radius = JengaLayout.plinthRadius * 0.7 + (JengaLayout.terrainRadius - JengaLayout.plinthRadius * 0.7) * t
            let wobble = i == 0 || i == rings ? 0 : 0.35 * (JengaLayout.terrainRadius / Float(rings))
            pts.append((0..<segs).map { k in
                let a = (Float(k) + (i % 2 == 0 ? 0 : 0.5) + (r.nextFloat() - 0.5) * 0.5) / Float(segs) * 2 * .pi
                let rad = radius + (r.nextFloat() - 0.5) * wobble
                return [cos(a) * rad, 0, sin(a) * rad]
            })
        }
        func gs(_ p: SIMD3<Float>) -> SIMD4<Float> {
            [JengaPart.terrain.rawValue, simd_length(SIMD2(p.x, p.z)) / JengaLayout.terrainRadius, 0, 0]
        }
        for i in 0..<rings {
            for k in 0..<segs {
                let a = pts[i][k], b = pts[i][(k + 1) % segs], c = pts[i + 1][k], d = pts[i + 1][(k + 1) % segs]
                if i % 2 == 0 {
                    tri(a, c, b, up, up, up, shape: (gs(a), gs(c), gs(b)))
                    tri(b, c, d, up, up, up, shape: (gs(b), gs(c), gs(d)))
                } else {
                    tri(a, d, b, up, up, up, shape: (gs(a), gs(d), gs(b)))
                    tri(a, c, d, up, up, up, shape: (gs(a), gs(c), gs(d)))
                }
            }
        }

        // The plinth: eight sides, narrower at the top, reaching below the ground.
        let ps = SIMD4<Float>(JengaPart.plinth.rawValue, 0, 0, 0)
        let bottom = JengaLayout.ground - JengaLayout.plinthTop - 0.3
        func pr(_ k: Int, _ rad: Float, _ y: Float) -> SIMD3<Float> {
            let a = (Float(k) + 0.5) / 8 * 2 * .pi
            return [cos(a) * rad, y, sin(a) * rad]
        }
        for k in 0..<8 {
            let a = pr(k, JengaLayout.plinthRadius, 0), b = pr(k + 1, JengaLayout.plinthRadius, 0)
            let c = pr(k + 1, JengaLayout.plinthRadius * 1.2, bottom), d = pr(k, JengaLayout.plinthRadius * 1.2, bottom)
            let n = simd_normalize(pr(k, 1, 0) + pr(k + 1, 1, 0))
            tri(a, b, c, n, n, n, shape: (ps, ps, ps), hide: 2)
            tri(a, c, d, n, n, n, shape: (ps, ps, ps), hide: 4)
            tri(.zero, b, a, up, up, up, shape: (ps, ps, ps), hide: 6)
        }

        // The blocks.
        let corners: [SIMD3<Float>] = [[-0.5, -0.5, -0.5], [0.5, -0.5, -0.5], [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
                                       [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5], [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5]]
        let faces: [(Int, Int, Int, Int, SIMD3<Float>)] = [
            (0, 3, 2, 1, [0, 0, -1]), (4, 5, 6, 7, [0, 0, 1]), (0, 4, 7, 3, [-1, 0, 0]),
            (1, 2, 6, 5, [1, 0, 0]), (3, 7, 6, 2, [0, 1, 0]), (0, 1, 5, 4, [0, -1, 0]),
        ]
        for i in 0..<JengaLayout.maxBodies {
            let s = SIMD4<Float>(JengaPart.block.rawValue, Float(i), 0, 0)
            for (a, b, c, d, n) in faces {
                let face = r.nextFloat()
                tri(corners[a], corners[b], corners[c], n, n, n, shape: (s, s, s), rand: face, hide: 2)
                tri(corners[a], corners[c], corners[d], n, n, n, shape: (s, s, s), rand: face, hide: 4)
            }
        }

        hand(sides: sides, segments: 2)
    }
}

/// Jenga: a hand builds a tower on a plinth, one block each time Place fires, layer on layer
/// across each other, up to `layers`. Quake, plus the bass of the spectrum mapped in × `stage`,
/// shakes the plinth: it jumps up by `bounce` and jitters, the tower sways (the spectrum's mids
/// sway it too), and blocks that the shake beats their grip on slide out. Higher blocks and
/// lonelier ones hold on less, so a kick chips at the top; a jump in the shake that lasts (a
/// drop) hits every layer. A block whose layer below has lost its middle and a side tips over
/// toward the gap, taking everything above with it. Fallen blocks tumble, bounce off the plinth and the ground, and
/// crumble away over `fade` seconds once they land. The hand keeps building on whatever's left.
/// Fallen blocks don't hit each other or the tower: they only meet the ground.
///
/// Writes, each step, into the next of four buffers, as float4s: [0] = the plinth's offset
/// (x, y, z, 0); [1] = where the hand holds its block (x, y, z, grip 0 open...1 closed);
/// [2] = (the hand's yaw, 0, 0, 0); then two per block: (x, y, z, size 0...1, 0 for none) and
/// its rotation as a quaternion (ix, iy, iz, r). Must match jenga.metal.
final class JengaSim: GeoSim {
    enum State { case free, carried, placed, loose }
    struct Body {
        var state = State.free
        var pos = SIMD3<Float>.zero, vel = SIMD3<Float>.zero
        var rot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), spin = SIMD3<Float>.zero
        var layer = 0, slot = 0
        /// 1 whole, crumbling to 0 once it has landed.
        var alpha: Float = 0
        var landed = false, asleep = false
        /// A placed block's small offset (x, z) and turn from true, so the tower isn't perfect.
        var jitter = SIMD3<Float>.zero
    }

    static let gravity: Float = 9
    /// The hand mesh's yaw at rest, between the two ways the layers run.
    private static let restYaw: Float = -.pi / 4

    private let buffers: [MTLBuffer]
    private var index = 0
    var current: MTLBuffer { buffers[index] }

    private(set) var bodies = [Body](repeating: Body(), count: JengaLayout.maxBodies)
    /// Layer × 3 + slot → the placed block there, or -1.
    private var grid = [Int](repeating: -1, count: JengaLayout.maxLayers * 3)
    private var started = false
    private var time: Float = 0
    private var rng = SplitMix(seed: 0x4E6A)

    private(set) var plinth = SIMD3<Float>.zero
    private var plinthVel = SIMD3<Float>.zero
    private var sway = SIMD2<Float>.zero, swayVel = SIMD2<Float>.zero
    /// Quake averaged over about a quarter second and over about three: the gap between them is a
    /// drop, a jump in how hard it shakes that lasts, not a single kick.
    private var quakeFast: Float = 0, quakeSlow: Float = 0

    // The hand: where its block is, its yaw, how closed, and how far through a placement (nil: resting).
    private(set) var handPos = SIMD3<Float>.zero
    private var handYaw = JengaSim.restYaw
    private var grip: Float = 1
    private(set) var phase: Float?
    private var pending = 0
    private var placeSeen: Float?
    private var carried: Int?
    private var phaseStart = SIMD3<Float>.zero

    var placedCount: Int { bodies.filter { $0.state == .placed }.count }
    var looseCount: Int { bodies.filter { $0.state == .loose }.count }
    var isFinite: Bool {
        bodies.allSatisfy { $0.pos.x.isFinite && $0.pos.y.isFinite && $0.pos.z.isFinite && $0.rot.vector.w.isFinite }
            && handPos.x.isFinite && plinth.y.isFinite
    }

    init(device: MTLDevice) {
        let length = (JengaLayout.bodyOffset + 2 * JengaLayout.maxBodies) * MemoryLayout<SIMD4<Float>>.stride
        buffers = (0..<4).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
    }

    func step(_ bank: ParamBank, dt rawDt: Float, spectrum: SpectrumTextures?) {
        let dt = min(max(rawDt, 0), 0.1)
        let layers = min(max(Int(bank.live("layers").rounded()), 1), JengaLayout.maxLayers)
        if !started {
            // The tower starts built, the hand holding the next block.
            for k in 0..<layers { for s in 0..<3 { if let i = freeBody() { place(i, k, s) } } }
            started = true
        }
        time += dt

        shakePlinth(bank, dt, spectrum)
        placeBlocks(layers)
        dislodge(bank, dt, layers)
        rebuildGrid()
        topple()
        moveHand(bank, dt, layers)
        rebuildGrid()
        fall(bank, dt)
        write()
    }

    // MARK: Quake

    /// Smooth wobble -1...1, different for each salt.
    private func wobble(_ t: Float, _ salt: Float) -> Float {
        (sin(t * 1.0 + salt * 1.7) + sin(t * 1.618 + salt * 4.1) * 0.6 + sin(t * 2.71 + salt * 2.3) * 0.4) / 2
    }

    /// How hard the ground shakes: quake, plus the bass of the spectrum mapped in × stage, 0...1.
    private var shake: Float = 0

    /// The plinth springs toward the shake × bounce up and jitters about; the tower top sways
    /// after it, and with the spectrum's mids.
    private func shakePlinth(_ bank: ParamBank, _ dt: Float, _ spectrum: SpectrumTextures?) {
        let stage = max(bank.live("stage"), 0)
        let bass = (spectrum?.level(0, 0.22) ?? 0) * stage, mids = (spectrum?.level(0.3, 0.7) ?? 0) * stage
        shake = min(max(bank.live("quake"), 0) + bass, 1)
        let q = shake, bounce = max(bank.live("bounce"), 0)
        quakeFast += (q - quakeFast) * min(1, dt * 4)
        quakeSlow += (q - quakeSlow) * min(1, dt * 0.3)
        let jitter = SIMD3<Float>(wobble(time * 23, 1), 0, wobble(time * 19, 2)) * q * bounce * 0.05
        let target = SIMD3<Float>(0, q * bounce * 0.25, 0) + jitter
        plinthVel += ((target - plinth) * 150 - plinthVel * 8) * dt
        plinth += plinthVel * dt

        let s = max(bank.live("sway"), 0)
        let swayTarget = SIMD2<Float>(wobble(time * 3.1, 5), wobble(time * 2.7, 6)) * (q + mids) * s * 0.08
        swayVel += ((swayTarget - sway) * 80 - swayVel * 6) * dt
        sway += swayVel * dt
    }

    /// Placed blocks ride the plinth, leaning further with the sway the higher they are.
    private func placeBlocks(_ layers: Int) {
        let towerHeight = Float(layers) * JengaLayout.height
        for i in bodies.indices where bodies[i].state == .placed {
            let (home, yaw) = JengaLayout.home(bodies[i].layer, bodies[i].slot)
            let lean = (home.y - JengaLayout.plinthTop) / towerHeight
            let j = bodies[i].jitter
            bodies[i].pos = home + plinth + SIMD3(sway.x, 0, sway.y) * lean + SIMD3(j.x, 0, j.y)
            bodies[i].rot = simd_quatf(angle: yaw + j.z, axis: [0, 1, 0])
            bodies[i].vel = plinthVel
        }
    }

    /// Blocks the shake beats their grip on slide out along their length.
    private func dislodge(_ bank: ParamBank, _ dt: Float, _ layers: Int) {
        let q = shake, grip = bank.live("grip")
        let jolt = max(0, quakeFast - quakeSlow - 0.15)
        guard (q * 0.6 + jolt * 2) * 1.2 * 1.4 > grip else { return }
        for i in bodies.indices where bodies[i].state == .placed {
            let k = bodies[i].layer
            let h = Float(k + 1) / Float(max(layers, k + 1))
            let n = (grid[k * 3] >= 0 ? 1 : 0) + (grid[k * 3 + 1] >= 0 ? 1 : 0) + (grid[k * 3 + 2] >= 0 ? 1 : 0)
            let stress = (q * 0.6 + jolt * 2) * (0.3 + 0.9 * h * h) * (n == 1 ? 1.4 : n == 2 ? 1.15 : 1)
            guard stress > grip, rng.nextFloat() < (stress - grip) * 4 * dt else { continue }
            let along = bodies[i].rot.act([1, 0, 0]) * (rng.nextFloat() < 0.5 ? -1 : 1)
            let side = SIMD3<Float>(rng.nextFloat() - 0.5, 0, rng.nextFloat() - 0.5)
            loosen(i, vel: plinthVel + along * (0.3 + 0.6 * rng.nextFloat()) * min(stress, 1.5) + side * 0.2 + [0, 0.3 * jolt, 0],
                   spin: randomUnit() * 3 * rng.nextFloat())
        }
    }

    /// A block whose layer below has lost its middle and a side (or everything) tips toward the
    /// gap, with everything above it, as one piece turning about the edge it tips over.
    private func topple() {
        for k in 1..<JengaLayout.maxLayers {
            guard (0..<3).contains(where: { grid[k * 3 + $0] >= 0 }) else { continue }
            let l = grid[(k - 1) * 3] >= 0, m = grid[(k - 1) * 3 + 1] >= 0, r = grid[(k - 1) * 3 + 2] >= 0
            if m || (l && r) { continue }
            let across: SIMD3<Float> = (k - 1) % 2 == 0 ? [0, 0, 1] : [1, 0, 0]
            var dir: SIMD3<Float>, pivot: SIMD3<Float>
            if l || r {
                let s = l ? 0 : 2
                dir = across * (l ? 1 : -1)
                pivot = JengaLayout.home(k - 1, s).pos + dir * JengaLayout.width / 2
            } else {
                let a = rng.nextFloat() * 2 * .pi
                dir = [cos(a), 0, sin(a)]
                pivot = JengaLayout.home(k - 1, 1).pos
            }
            pivot += plinth + [0, JengaLayout.height / 2, 0]
            let w = simd_cross([0, 1, 0], dir) * (1 + rng.nextFloat())
            for i in bodies.indices where bodies[i].state == .placed && bodies[i].layer >= k {
                loosen(i, vel: plinthVel + simd_cross(w, bodies[i].pos - pivot) + randomUnit() * 0.15,
                       spin: w + randomUnit() * 0.5)
            }
            return
        }
    }

    // MARK: The hand

    /// The next block's place: the top layer's first gap, in the order the layer is built
    /// (alternate layers left to right and back), or the first of a new layer while there's room.
    private func target(_ layers: Int) -> (layer: Int, slot: Int)? {
        var top = -1
        for k in stride(from: JengaLayout.maxLayers - 1, through: 0, by: -1)
        where grid[k * 3] >= 0 || grid[k * 3 + 1] >= 0 || grid[k * 3 + 2] >= 0 {
            top = k
            break
        }
        func slot(_ k: Int, _ n: Int) -> Int { k % 2 == 0 ? n : 2 - n }
        if top >= 0, let n = (0..<3).first(where: { grid[top * 3 + slot(top, $0)] < 0 }) { return (top, slot(top, n)) }
        guard top + 1 < layers else { return nil }
        return (top + 1, slot(top + 1, 0))
    }

    /// Where the hand rests between placements: above the tower and off to one side.
    private func restPos() -> SIMD3<Float> {
        var top = -1
        for k in 0..<JengaLayout.maxLayers where grid[k * 3] >= 0 || grid[k * 3 + 1] >= 0 || grid[k * 3 + 2] >= 0 { top = k }
        let topY = JengaLayout.plinthTop + Float(top + 1) * JengaLayout.height
        let d = SIMD3<Float>(cos(Self.restYaw), 0, sin(Self.restYaw))
        return plinth + [0, topY + 0.55 + 0.03 * sin(time * 1.3), 0] - d * 0.9
    }

    private static func ease(_ t: Float) -> Float { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }

    /// Each Place fire takes the held block to the next gap: over the tower, down, let go,
    /// and back up to the rest for the next block. One fire waits while it's busy.
    private func moveHand(_ bank: ParamBank, _ dt: Float, _ layers: Int) {
        let fired = bank.triggerCount("place")
        if let seen = placeSeen { pending = min(pending + Int(fired - seen), 1) }
        placeSeen = fired

        let rest = restPos()
        if carried == nil, phase == nil, let i = freeBody() ?? fadingBody() {
            bodies[i] = Body(state: .carried, pos: rest, alpha: 0)
            carried = i
        }
        if let c = carried, bodies[c].state == .carried { bodies[c].alpha = min(1, bodies[c].alpha + dt / 0.2) }

        let goal = target(layers)
        if phase == nil, pending > 0 {
            pending -= 1
            if goal != nil, carried != nil { phase = 0; phaseStart = handPos }
        }

        if var t = phase {
            t += dt / max(bank.live("placeTime"), 0.05)
            let to = goal.map { JengaLayout.home($0.layer, $0.slot) }
            let spot = to.map { $0.pos + plinth + SIMD3(sway.x, 0, sway.y) * ($0.pos.y - JengaLayout.plinthTop) / (Float(layers) * JengaLayout.height) }
            let placeYaw: Float = goal.map { $0.layer % 2 == 0 ? -.pi / 2 : 0 } ?? Self.restYaw
            let above = (spot ?? rest) + [0, 0.35, 0]
            if t < 0.45 {
                let e = Self.ease(t / 0.45)
                handPos = simd_mix(phaseStart, above, SIMD3(repeating: e)) + [0, sin(e * .pi) * 0.2, 0]
                handYaw = Self.restYaw + (placeYaw - Self.restYaw) * e
                grip = 1
            } else if t < 0.65 {
                handPos = simd_mix(above, spot ?? rest, SIMD3(repeating: Self.ease((t - 0.45) / 0.2)))
                handYaw = placeYaw
            } else if t < 0.75 {
                handPos = spot ?? rest
                grip = 1 - (t - 0.65) / 0.1
                if t >= 0.7, let c = carried {
                    // Let go: into its gap, or dropped if there's no gap any more.
                    if let goal { place(c, goal.layer, goal.slot) } else { loosen(c, vel: plinthVel, spin: .zero) }
                    carried = nil
                }
            } else {
                let from = (spot ?? rest) + [0, 0.02, 0]
                let e = Self.ease((t - 0.75) / 0.25)
                handPos = simd_mix(from, rest, SIMD3(repeating: e)) + [0, sin(e * .pi) * 0.15, 0]
                handYaw = placeYaw + (Self.restYaw - placeYaw) * e
                grip = 0
            }
            if t >= 1 {
                phase = nil
                grip = 1
            } else {
                phase = t
            }
            if phase == nil, let c = carried {
                // Let go mid-way when the trigger outran it.
                place(c, goal?.layer ?? 0, goal?.slot ?? 0)
                carried = nil
            }
        } else {
            handPos = rest
            handYaw = Self.restYaw
            grip = 1
        }

        if let c = carried, bodies[c].state == .carried {
            bodies[c].pos = handPos
            bodies[c].rot = simd_quatf(angle: -handYaw - .pi / 2, axis: [0, 1, 0])
            bodies[c].vel = .zero
        }
    }

    // MARK: Falling

    /// Fallen blocks: gravity, spin, and impacts at their corners with the plinth and the ground.
    private func fall(_ bank: ParamBank, _ dt: Float) {
        let fade = max(bank.live("fade"), 0)
        let half = SIMD3<Float>(JengaLayout.length, JengaLayout.height, JengaLayout.width) / 2
        let inv = SIMD3<Float>(12 / (JengaLayout.height * JengaLayout.height + JengaLayout.width * JengaLayout.width),
                               12 / (JengaLayout.length * JengaLayout.length + JengaLayout.width * JengaLayout.width),
                               12 / (JengaLayout.length * JengaLayout.length + JengaLayout.height * JengaLayout.height))
        let steps = 2
        let h = dt / Float(steps)
        for i in bodies.indices where bodies[i].state == .loose {
            var b = bodies[i]
            if !b.asleep {
                for _ in 0..<steps {
                    b.vel.y -= Self.gravity * h
                    b.pos += b.vel * h
                    let w = simd_length(b.spin)
                    if w > 1e-5 { b.rot = (simd_quatf(angle: w * h, axis: b.spin / w) * b.rot).normalized }
                    func invI(_ v: SIMD3<Float>) -> SIMD3<Float> { b.rot.act(inv * b.rot.inverse.act(v)) }

                    var deepest: Float = 0, touching = false
                    for c in 0..<8 {
                        let corner = SIMD3<Float>(c & 1 == 0 ? -1 : 1, c & 2 == 0 ? -1 : 1, c & 4 == 0 ? -1 : 1) * half
                        let r = b.rot.act(corner)
                        let p = b.pos + r
                        let onPlinth = simd_length(SIMD2(p.x - plinth.x, p.z - plinth.z)) < JengaLayout.plinthRadius
                        let floor = onPlinth ? JengaLayout.plinthTop + plinth.y : JengaLayout.ground
                        let depth = floor - p.y
                        guard depth > 0 else { continue }
                        touching = true
                        deepest = max(deepest, depth)
                        let surface = onPlinth ? plinthVel : .zero
                        let v = b.vel + simd_cross(b.spin, r) - surface
                        guard v.y < 0 else { continue }
                        let n = SIMD3<Float>(0, 1, 0)
                        let e: Float = v.y < -0.6 ? 0.3 : 0
                        let j = -(1 + e) * v.y / (1 + simd_dot(n, simd_cross(invI(simd_cross(r, n)), r)))
                        b.vel += n * j
                        b.spin += invI(simd_cross(r, n * j))
                        // Friction, up to 0.6 of the push.
                        let vt = SIMD3<Float>(v.x, 0, v.z), speed = simd_length(vt)
                        if speed > 1e-4 {
                            let t = vt / speed
                            let kt = 1 + simd_dot(t, simd_cross(invI(simd_cross(r, t)), r))
                            let jt = min(speed / kt, 0.6 * j)
                            b.vel -= t * jt
                            b.spin -= invI(simd_cross(r, t * jt))
                        }
                    }
                    b.pos.y += deepest * 0.8
                    if touching {
                        b.landed = true
                        b.vel *= 0.99
                        b.spin *= 0.97
                    }
                }
                let offPlinth = simd_length(SIMD2(b.pos.x - plinth.x, b.pos.z - plinth.z)) > JengaLayout.plinthRadius + 0.5
                if b.landed, offPlinth, simd_length(b.vel) < 0.05, simd_length(b.spin) < 0.1 { b.asleep = true }
            }
            if b.landed { b.alpha = fade > 0 ? b.alpha - dt / fade : 0 }
            if b.alpha <= 0 || b.pos.y < JengaLayout.ground - 5 { b = Body() }
            bodies[i] = b
        }
    }

    // MARK: Bodies

    private func freeBody() -> Int? { bodies.firstIndex { $0.state == .free } }

    /// The fallen block nearest gone, to reuse when none is free.
    private func fadingBody() -> Int? {
        bodies.indices.filter { bodies[$0].state == .loose && bodies[$0].landed }.min { bodies[$0].alpha < bodies[$1].alpha }
    }

    private func randomUnit() -> SIMD3<Float> {
        simd_normalize(SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) + 1e-4)
    }

    private func place(_ i: Int, _ layer: Int, _ slot: Int) {
        guard grid[layer * 3 + slot] < 0 else { loosen(i, vel: plinthVel, spin: .zero); return }
        bodies[i].state = .placed
        bodies[i].layer = layer
        bodies[i].slot = slot
        bodies[i].alpha = 1
        bodies[i].jitter = SIMD3(rng.nextFloat() - 0.5, rng.nextFloat() - 0.5, rng.nextFloat() - 0.5) * [0.016, 0.016, 0.04]
        grid[layer * 3 + slot] = i
    }

    private func loosen(_ i: Int, vel: SIMD3<Float>, spin: SIMD3<Float>) {
        if bodies[i].state == .placed { grid[bodies[i].layer * 3 + bodies[i].slot] = -1 }
        bodies[i].state = .loose
        bodies[i].vel = vel
        bodies[i].spin = spin
        bodies[i].landed = false
        bodies[i].asleep = false
    }

    private func rebuildGrid() {
        for g in grid.indices { grid[g] = -1 }
        for i in bodies.indices where bodies[i].state == .placed { grid[bodies[i].layer * 3 + bodies[i].slot] = i }
    }

    private func write() {
        let out = buffers[(index + 1) % buffers.count].contents().bindMemory(
            to: SIMD4<Float>.self, capacity: JengaLayout.bodyOffset + 2 * JengaLayout.maxBodies)
        out[0] = SIMD4(plinth, 0)
        out[JengaLayout.handOffset] = SIMD4(handPos, grip)
        out[JengaLayout.handOffset + 1] = [handYaw, 0, 0, 0]
        for (i, b) in bodies.enumerated() {
            out[JengaLayout.bodyOffset + 2 * i] = SIMD4(b.pos, b.state == .free ? 0 : max(b.alpha, 0))
            out[JengaLayout.bodyOffset + 2 * i + 1] = b.rot.vector
        }
        index = (index + 1) % buffers.count
    }
}
