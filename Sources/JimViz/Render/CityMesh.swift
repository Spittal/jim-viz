import Metal
import simd

/// City: a fixed tile of Manhattan blocks seen from above. The mesh holds the ground once and one
/// block's worth of everything; the shader draws it instanced, instance 0 for the ground (land,
/// river, the base's sides) and one instance per block, and each block keeps only what it is
/// (buildings or a park, piers on the waterfront). Cars and people come from `CitySim`, read at
/// buffer(4). Which part a face is sits in shape.w (`CityPart`), which slot of its kind (lot,
/// tree, lamp, corner, car, person) in shape.z, which thing it belongs to in shape.y
/// (`CityGroup`), and a part's own extra in shape.x.
/// - ground and pier: position = a unit box (0...1 on each axis, y 1 the top), shape.x = 0 for
///   the land, 1 for the river.
/// - block slab: a unit box; its top is the sidewalk and the block's middle, its sides the curb.
/// - building: a unit box for each tier, shape.x = the tier 0...2 (the ledge is tier 0's).
/// - rooftop things, trees, lamps, signals, cars and people: metres from their foot (x forward
///   for cars and people); the spire's height is a fraction of its length. Legs: shape.x = side.
/// Must match the constants in Shaders/generators/lowpoly/city.metal.
enum CityPart: Int {
    case land, water, base, sidewalk, curb, wall, roof, ledge, tank, hvac, spire, trunk, crown
    case post, lamp, signal, car, cabin, skin, clothes, legs, pier
}

/// What a face belongs to, which decides how the shader places it. Must match city.metal.
enum CityGroup: Int {
    case ground, slab, building, tree, lamp, signal, car, person, pier
}

/// What a block holds, per block instance. Must match city.metal.
enum CitySlots {
    static let lots = 8          // 2 deep (x) × 4 across (z)
    static let trees = 12
    static let lamps = 8         // 3 along each long side, 1 on each short side
    static let corners = 4
    static let cars = 8
    static let people = 16
    static let maxSide = 16
    static let maxBlocks = maxSide * maxSide
}

/// The tile's plan in metres, from the knobs. Avenues run along x, streets along z; blocks are
/// `blockX` along the avenues and `blockZ` between them. Roads ring the tile, so a block always
/// has a road on every side. Block (i, j) is the i-th along x, the j-th along z; instance
/// 1 + i + j × rows. Must match `Layout` in city.metal.
struct CityLayout {
    let rows: Int, cols: Int
    let blockX: Float, blockZ: Float
    let streetW: Float, avenueW: Float, sidewalk: Float

    init(_ value: (String) -> Float) {
        rows = min(max(Int(value("length").rounded()), 1), CitySlots.maxSide)
        cols = min(max(Int(value("width").rounded()), 1), CitySlots.maxSide)
        blockX = max(value("blockLength"), 1)
        blockZ = max(value("blockWidth"), 1)
        streetW = max(value("street"), 1)
        avenueW = max(value("avenue"), 1)
        sidewalk = min(max(value("sidewalk"), 0.5), min(blockX, blockZ) * 0.3)
    }

    var blocks: Int { rows * cols }
    var pitchX: Float { blockX + streetW }
    var pitchZ: Float { blockZ + avenueW }
    var sizeX: Float { Float(rows) * pitchX + streetW }
    var sizeZ: Float { Float(cols) * pitchZ + avenueW }
    /// Roads along x (avenues), at z, and along z (streets), at x.
    var avenues: Int { cols + 1 }
    var streets: Int { rows + 1 }
    func avenueZ(_ k: Int) -> Float { -sizeZ / 2 + avenueW / 2 + Float(k) * pitchZ }
    func streetX(_ k: Int) -> Float { -sizeX / 2 + streetW / 2 + Float(k) * pitchX }
    /// The corner of block (i, j) with the least x and z.
    func blockMin(_ i: Int, _ j: Int) -> SIMD2<Float> {
        [-sizeX / 2 + streetW + Float(i) * pitchX, -sizeZ / 2 + avenueW + Float(j) * pitchZ]
    }
    /// Lanes each way on a road this wide.
    static func lanes(_ width: Float) -> Int { min(max(Int(width / 2 / 3.2), 1), 6) }
    /// How far before an intersection the crossing starts, and so where cars stop.
    var crosswalk: Float { max(3, sidewalk) }
}

extension MeshBuilder {
    /// The ground, then one block: its slab, lots, trees, lamps, signals, cars, people and pier.
    mutating func city(detail: Int) {
        var k = CityKit()
        // Ground: the land and the river, each a box whose top is level.
        k.group = .ground
        k.slot = 0
        k.extra = 0
        k.box([0, 0, 0], [1, 1, 1], side: .base, top: .land)
        k.extra = 1
        k.box([0, 0, 0], [1, 1, 1], side: .base, top: .water)
        k.extra = 0
        k.group = .slab
        k.box([0, 0, 0], [1, 1, 1], side: .curb, top: .sidewalk)
        k.group = .building
        for lot in 0..<CitySlots.lots {
            k.slot = Float(lot)
            for tier in 0..<(detail == 0 ? 1 : 3) {
                k.extra = Float(tier)
                k.box([0, 0, 0], [1, 1, 1], side: .wall, top: .roof)
            }
            k.extra = 0
            guard detail > 0 else { continue }
            // A water tower on a stand, and a plant room.
            k.box([-0.7, 0, -0.7], [0.7, 2.2, 0.7], side: .post, top: .post)
            k.loft([(1.6, 2.2), (1.6, 5), (0, 6.3)], sides: 6, .tank, bottomCap: true)
            k.box([-1.6, 0, -1.1], [1.6, 1.5, 1.1], side: .hvac, top: .hvac)
            if detail > 1 {
                k.box([0, 0, 0], [1, 1, 1], side: .ledge, top: .ledge, bottom: .ledge)
                k.loft([(1, 0), (0, 1)], sides: 4, .spire)
            }
        }
        k.group = .tree
        for tree in 0..<CitySlots.trees {
            k.slot = Float(tree)
            k.loft([(0.25, 0), (0.2, 2.4)], sides: 4, .trunk)
            k.loft([(0, 1.6), (2.2, 3.4), (0, 5.8)], sides: 5, .crown)
        }
        k.group = .lamp
        for lamp in 0..<CitySlots.lamps {
            k.slot = Float(lamp)
            k.loft([(0.1, 0), (0.08, 6)], sides: 4, .post)
            k.box([-0.4, 5.8, -0.4], [0.4, 6.2, 0.4], side: .lamp, top: .post, bottom: .lamp)
        }
        k.group = .signal
        for corner in 0..<CitySlots.corners {
            k.slot = Float(corner)
            k.loft([(0.12, 0), (0.12, 4.4)], sides: 4, .post)
            k.box([-0.3, 3.2, -0.3], [0.3, 4.4, 0.3], side: .signal, top: .post, bottom: .post)
        }
        k.extra = 0
        k.group = .car
        for car in 0..<CitySlots.cars {
            k.slot = Float(car)
            k.box([-2.2, 0.25, -0.9], [2.2, 1.0, 0.9], side: .car, top: .car, bottom: .post)
            k.frustum([-1.3, 0.8, -0.8, 0.8], 1.0, [-1.0, 0.45, -0.7, 0.7], 1.5, side: .cabin, top: .car)
        }
        k.group = .person
        for person in 0..<CitySlots.people {
            k.slot = Float(person)
            for side: Float in [-1, 1] {
                k.extra = side
                k.box([-0.08, 0, side * 0.11 - 0.07], [0.08, 0.85, side * 0.11 + 0.07], side: .legs, top: nil)
            }
            k.extra = 0
            k.box([-0.12, 0.85, -0.21], [0.12, 1.45, 0.21], side: .clothes, top: .clothes)
            k.box([-0.11, 1.5, -0.11], [0.11, 1.74, 0.11], side: .skin, top: .skin)
        }
        k.group = .pier
        k.slot = 0
        k.box([0, 0, 0], [1, 1, 1], side: .base, top: .pier)
        vertices += k.vertices
    }
}

/// Builds the city's faces. Points are in each part's own units; see `CityPart`.
private struct CityKit {
    var vertices: [MeshVertex] = []
    var group = CityGroup.ground
    var slot: Float = 0
    var extra: Float = 0
    private var rng = SplitMix(seed: 0xC17)

    /// A triangle, its normal turned away from `centre`.
    mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ part: CityPart, centre: SIMD3<Float>) {
        var n = simd_normalize(simd_cross(b - a, c - a))
        if !n.x.isFinite { n = [0, 1, 0] }
        if simd_dot(n, (a + b + c) / 3 - centre) < 0 { n = -n }
        let r = rng.nextFloat()
        let bary: [SIMD4<Float>] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
        for (i, p) in [a, b, c].enumerated() {
            vertices.append(MeshVertex(position: SIMD4(p, r), faceNormal: SIMD4(n, 0), smoothNormal: SIMD4(n, 0),
                                       bary: bary[i], shape: [extra, Float(group.rawValue), slot, Float(part.rawValue)]))
        }
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ part: CityPart,
                       centre: SIMD3<Float>) {
        tri(a, b, c, part, centre: centre)
        tri(a, c, d, part, centre: centre)
    }

    /// A box from lo to hi: four sides, a top unless nil, and a bottom when given.
    mutating func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, side: CityPart, top: CityPart?, bottom: CityPart? = nil) {
        frustum([lo.x, hi.x, lo.z, hi.z], lo.y, [lo.x, hi.x, lo.z, hi.z], hi.y, side: side, top: top)
        if let bottom {
            quad([lo.x, lo.y, lo.z], [hi.x, lo.y, lo.z], [hi.x, lo.y, hi.z], [lo.x, lo.y, hi.z], bottom,
                 centre: (lo + hi) / 2)
        }
    }

    /// Four sides from rectangle r0 (x0, x1, z0, z1) at y0 up to r1 at y1, and a cap on r1.
    mutating func frustum(_ r0: SIMD4<Float>, _ y0: Float, _ r1: SIMD4<Float>, _ y1: Float, side: CityPart, top: CityPart?) {
        let a: [SIMD3<Float>] = [[r0.x, y0, r0.z], [r0.y, y0, r0.z], [r0.y, y0, r0.w], [r0.x, y0, r0.w]]
        let b: [SIMD3<Float>] = [[r1.x, y1, r1.z], [r1.y, y1, r1.z], [r1.y, y1, r1.w], [r1.x, y1, r1.w]]
        let centre = (a.reduce(.zero, +) + b.reduce(.zero, +)) / 8 - [0, 0.001, 0]
        for k in 0..<4 { quad(a[k], a[(k + 1) % 4], b[(k + 1) % 4], b[k], side, centre: centre) }
        if let top { quad(b[0], b[1], b[2], b[3], top, centre: centre) }
    }

    /// A prism of `sides` sides round the y axis through rings (radius, y). A ring of radius 0
    /// closes it to a point; `bottomCap` closes the first ring.
    mutating func loft(_ rings: [(r: Float, y: Float)], sides: Int, _ part: CityPart, bottomCap: Bool = false) {
        func p(_ ring: (r: Float, y: Float), _ k: Int) -> SIMD3<Float> {
            let a = (Float(k) + 0.5) / Float(sides) * 2 * .pi
            return [cos(a) * ring.r, ring.y, sin(a) * ring.r]
        }
        for i in 0..<rings.count - 1 {
            let centre = SIMD3<Float>(0, (rings[i].y + rings[i + 1].y) / 2, 0)
            for k in 0..<sides {
                let a = p(rings[i], k), b = p(rings[i], k + 1), c = p(rings[i + 1], k + 1), d = p(rings[i + 1], k)
                if rings[i + 1].r == 0 { tri(a, b, c, part, centre: centre) }
                else if rings[i].r == 0 { tri(a, c, d, part, centre: centre) }
                else { quad(a, b, c, d, part, centre: centre) }
            }
        }
        if bottomCap, let first = rings.first, first.r > 0 {
            let c = SIMD3<Float>(0, first.y, 0)
            for k in 0..<sides { tri(p(first, k), p(first, k + 1), c, part, centre: c + [0, 1, 0]) }
        }
    }
}

/// A geo's simulation, stepped on the render thread each frame and read by its vertex shader
/// at buffer(4).
protocol GeoSim: AnyObject {
    /// The buffer the last step wrote. Render thread.
    var current: MTLBuffer { get }
    /// Render thread, once per frame after the knobs are set and triggers counted.
    func step(_ bank: ParamBank, dt: Float)
}

/// City's traffic and people. Cars drive straight along their lane (right-hand traffic), keep
/// their distance from the car ahead, and stop at red lights; off the end of the tile they come
/// back in at the other end. People walk round their block's sidewalk and, at a corner, may
/// cross to the next block when their way has the green. The lights are one phase for the whole
/// city: avenues (along x) or streets (along z) have the green, swapped every `cycle` seconds
/// and each time Lights Change fires.
///
/// Writes, each step, into the next of four buffers (more than the frames in flight), as float4s:
/// [0] = (avenues have the green 1/0, 0, 0, 0); then `CitySlots.maxBlocks × cars` cars,
/// (x, z, heading, w) with w 0 for a car that isn't there, its size 0...1 (shrinking off the
/// tile's ends), negative while braking; then the people, (x, z, heading, distance walked), w -1
/// for one who isn't there. Car c and person p are block c / cars's and p / people's slots.
/// Must match city.metal.
final class CitySim: GeoSim {
    static let maxCars = CitySlots.maxBlocks * CitySlots.cars
    static let maxPeople = CitySlots.maxBlocks * CitySlots.people
    static let peopleOffset = 1 + maxCars
    static let carLength: Float = 4.4
    private static let maxLanes = 2 * (CitySlots.maxSide + 1) * 2 * 6

    private let buffers: [MTLBuffer]
    private var index = 0
    var current: MTLBuffer { buffers[index] }

    /// Whether the avenues (along x) have the green.
    private(set) var avenuesGreen = true
    private var lightTimer: Float = 0
    private var lightsSeen: Float?
    private var started = false

    // Cars: which road and lane (taken modulo the layout's, so changing it keeps them on the
    // road), which way, how far along, how fast.
    private(set) var carAlongZ: [Bool]
    private var carRoad: [Int], carLane: [Int], carDir: [Float]
    private(set) var carS: [Float], carV: [Float]
    private var carPace: [Float], carKey: [Float]
    /// The crossing a car was too close to stop for when its light went red, which it drives on through; -1 for none.
    private var carPass: [Int]
    private(set) var carOn: [Bool]
    private var carLaneKey: [Int], laneStart: [Int], laneFill: [Int], sorted: [Int]

    // People: their block, how far round it, which way, and what they're doing.
    enum Walk: UInt8 { case walking, waiting, crossing }
    private var pI: [Int], pJ: [Int]
    private var pU: [Float], pDir: [Float], pPace: [Float], pKey: [Float], pSide: [Float]
    private(set) var pWalk: [Walk]
    private var pLeg: [Int], pT: [Float], pPhase: [Float], pCorners: [UInt32]
    private(set) var pOn: [Bool]

    init(device: MTLDevice) {
        let length = (1 + Self.maxCars + Self.maxPeople) * MemoryLayout<SIMD4<Float>>.stride
        buffers = (0..<4).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
        var r = SplitMix(seed: 0xCA75)
        let n = Self.maxCars
        carAlongZ = (0..<n).map { _ in r.nextFloat() > 0.6 }
        carRoad = (0..<n).map { _ in Int(r.next() % 4096) }
        carLane = (0..<n).map { _ in Int(r.next() % 4096) }
        carDir = (0..<n).map { _ in r.nextFloat() < 0.5 ? 1 : -1 }
        carS = (0..<n).map { _ in r.nextFloat() }
        carV = [Float](repeating: 0, count: n)
        carPace = (0..<n).map { _ in 0.75 + 0.5 * r.nextFloat() }
        carKey = (0..<n).map { _ in r.nextFloat() }
        carOn = [Bool](repeating: false, count: n)
        carPass = [Int](repeating: -1, count: n)
        carLaneKey = [Int](repeating: 0, count: n)
        laneStart = [Int](repeating: 0, count: Self.maxLanes + 1)
        laneFill = [Int](repeating: 0, count: Self.maxLanes)
        sorted = [Int](repeating: 0, count: n)
        let m = Self.maxPeople
        pI = (0..<m).map { $0 / CitySlots.people % CitySlots.maxSide }
        pJ = (0..<m).map { $0 / CitySlots.people / CitySlots.maxSide }
        pU = (0..<m).map { _ in r.nextFloat() }
        pDir = (0..<m).map { _ in r.nextFloat() < 0.5 ? 1 : -1 }
        pPace = (0..<m).map { _ in 0.75 + 0.5 * r.nextFloat() }
        pKey = (0..<m).map { _ in r.nextFloat() }
        pSide = (0..<m).map { _ in r.nextFloat() - 0.5 }
        pWalk = [Walk](repeating: .walking, count: m)
        pLeg = [Int](repeating: 0, count: m)
        pT = [Float](repeating: 0, count: m)
        pPhase = (0..<m).map { _ in r.nextFloat() * 10 }
        pCorners = [UInt32](repeating: 0, count: m)
        pOn = [Bool](repeating: false, count: m)
    }

    func step(_ bank: ParamBank, dt rawDt: Float) {
        let dt = min(max(rawDt, 0), 0.1)
        let L = CityLayout(bank.live)
        if !started {
            // Spread everyone along their road or round their block.
            for c in carS.indices { carS[c] *= L.sizeX }
            for p in pU.indices { pU[p] *= 2 * (L.blockX + L.blockZ) }
            started = true
        }

        // The lights.
        let fired = bank.triggerCount("lights")
        let wasGreen = avenuesGreen
        if let seen = lightsSeen, seen != fired { avenuesGreen.toggle(); lightTimer = 0 }
        lightsSeen = fired
        lightTimer += dt
        let cycle = bank.live("cycle")
        if cycle > 0, lightTimer >= cycle { avenuesGreen.toggle(); lightTimer = 0 }
        if avenuesGreen != wasGreen { lightsChanged(L) }

        let out = buffers[(index + 1) % buffers.count].contents().bindMemory(
            to: SIMD4<Float>.self, capacity: 1 + Self.maxCars + Self.maxPeople)
        out[0] = [avenuesGreen ? 1 : 0, 0, 0, 0]
        stepCars(L, bank, dt, out + 1)
        stepPeople(L, bank, dt, out + Self.peopleOffset)
        index = (index + 1) % buffers.count
    }

    /// The next stop line ahead of a car at s on an avenue or a street, where it stops while the
    /// light is red: crossing m starts m pitches along, and the car stops short of its crosswalk.
    /// A line up to a metre behind still holds a car stopped at it.
    private static func nextStop(_ L: CityLayout, _ s: Float, alongZ: Bool) -> (m: Int, d: Float)? {
        let pitch = alongZ ? L.pitchZ : L.pitchX
        let back = L.crosswalk + 0.5 + carLength / 2
        let m = max(Int(((s + back - 1) / pitch).rounded(.up)), 1)
        guard m <= (alongZ ? L.cols : L.rows) else { return nil }
        return (m, Float(m) * pitch - back - s)
    }

    /// When the lights change, cars too close to stop for their new red drive on through it.
    private func lightsChanged(_ L: CityLayout) {
        for c in carPass.indices {
            carPass[c] = -1
            guard carOn[c], carAlongZ[c] == avenuesGreen, let stop = Self.nextStop(L, carS[c], alongZ: carAlongZ[c]) else { continue }
            if carV[c] >= 0.5, stop.d < carV[c] * carV[c] / 8 { carPass[c] = stop.m }
        }
    }

    private func stepCars(_ L: CityLayout, _ bank: ParamBank, _ dt: Float, _ out: UnsafeMutablePointer<SIMD4<Float>>) {
        let count = min(L.blocks * CitySlots.cars, Self.maxCars)
        let traffic = bank.live("traffic")
        let top = 13.9 * bank.live("carSpeed")  // 50 km/h
        let lanesX = CityLayout.lanes(L.avenueW), lanesZ = CityLayout.lanes(L.streetW)
        let keysX = L.avenues * 2 * lanesX
        let lanes = keysX + L.streets * 2 * lanesZ

        // Sort the cars by lane, then along it.
        for k in 0..<lanes { laneFill[k] = 0 }
        for c in 0..<Self.maxCars {
            carOn[c] = c < count && carKey[c] < traffic
            guard carOn[c] else { continue }
            let dirIndex = carDir[c] > 0 ? 0 : 1
            let key = carAlongZ[c]
                ? keysX + ((carRoad[c] % L.streets) * 2 + dirIndex) * lanesZ + carLane[c] % lanesZ
                : ((carRoad[c] % L.avenues) * 2 + dirIndex) * lanesX + carLane[c] % lanesX
            carLaneKey[c] = key
            laneFill[key] += 1
            let length = carAlongZ[c] ? L.sizeZ : L.sizeX
            if carS[c] >= length || carS[c] < 0 { carS[c] = carS[c] - (carS[c] / length).rounded(.down) * length }
        }
        laneStart[0] = 0
        for k in 0..<lanes { laneStart[k + 1] = laneStart[k] + laneFill[k]; laneFill[k] = 0 }
        for c in 0..<Self.maxCars where carOn[c] {
            let key = carLaneKey[c]
            var i = laneStart[key] + laneFill[key]
            laneFill[key] += 1
            // Insertion into the lane's run so far, by distance along.
            while i > laneStart[key], carS[sorted[i - 1]] > carS[c] { sorted[i] = sorted[i - 1]; i -= 1 }
            sorted[i] = c
        }

        let red = (avenues: !avenuesGreen, streets: avenuesGreen)
        for k in 0..<lanes {
            let start = laneStart[k], n = laneStart[k + 1] - start
            for idx in 0..<n {
                let c = sorted[start + idx]
                let alongZ = carAlongZ[c]
                let length = alongZ ? L.sizeZ : L.sizeX
                let s = carS[c], v = carV[c]
                // The car ahead, round the end of the lane for the last one.
                var room = Float.infinity
                if n > 1 {
                    let ahead = sorted[start + (idx + 1) % n]
                    room = carS[ahead] - s + (idx + 1 == n ? length : 0) - Self.carLength - 1.5
                }
                // The next stop line, if the light is red, unless it was too close to stop for.
                if alongZ ? red.streets : red.avenues, let stop = Self.nextStop(L, s, alongZ: alongZ), stop.m != carPass[c] {
                    room = min(room, max(stop.d, 0))
                }
                let want = min(top * carPace[c], max(room, 0) / 1.2)
                carV[c] = max(v + min(max(want - v, -9 * dt), 3 * dt), 0)
                let braking = want < v - 0.3
                carS[c] = s + carV[c] * dt

                // Where it is: right-hand lanes.
                let along = min(max(carS[c], 0), length)
                let dir = carDir[c]
                var x: Float, z: Float, heading: Float
                if alongZ {
                    let laneW = L.streetW / 2 / Float(lanesZ)
                    x = L.streetX(carRoad[c] % L.streets) - dir * (Float(carLane[c] % lanesZ) + 0.5) * laneW
                    z = dir > 0 ? -L.sizeZ / 2 + along : L.sizeZ / 2 - along
                    heading = dir > 0 ? .pi / 2 : -.pi / 2
                } else {
                    let laneW = L.avenueW / 2 / Float(lanesX)
                    z = L.avenueZ(carRoad[c] % L.avenues) + dir * (Float(carLane[c] % lanesX) + 0.5) * laneW
                    x = dir > 0 ? -L.sizeX / 2 + along : L.sizeX / 2 - along
                    heading = dir > 0 ? 0 : .pi
                }
                let size = max(min(min(along, length - along) / 6, 1), 0.01)
                out[c] = [x, z, heading, braking ? -size : size]
            }
        }
        for c in 0..<Self.maxCars where !carOn[c] { out[c] = .zero }
    }

    private func stepPeople(_ L: CityLayout, _ bank: ParamBank, _ dt: Float, _ out: UnsafeMutablePointer<SIMD4<Float>>) {
        let count = min(L.blocks * CitySlots.people, Self.maxPeople)
        let crowd = bank.live("crowd")
        let pace = 1.4 * bank.live("walk")
        let crossShare = bank.live("crossing")
        // The ring each block's people walk: legs 0...3 go +x, +z, -x, -z from corners 0...3.
        let q = L.sidewalk / 2
        let lx = max(L.blockX - 2 * q, 0.1), lz = max(L.blockZ - 2 * q, 0.1)
        let lens = SIMD4<Float>(lx, lz, lx, lz)
        let starts = SIMD4<Float>(0, lx, lx + lz, 2 * lx + lz)
        let perimeter = 2 * (lx + lz)
        func leg(_ u: Float) -> Int { u < starts[1] ? 0 : u < starts[2] ? 1 : u < starts[3] ? 2 : 3 }
        func way(_ l: Int) -> SIMD2<Float> { l == 0 ? [1, 0] : l == 1 ? [0, 1] : l == 2 ? [-1, 0] : [0, -1] }
        func corner(_ l: Int) -> SIMD2<Float> {
            [q + (l == 1 || l == 2 ? lx : 0), q + (l >= 2 ? lz : 0)]
        }

        for p in 0..<Self.maxPeople {
            pOn[p] = p < count && pKey[p] < crowd
            guard pOn[p] else { out[p] = [0, 0, 0, -1]; continue }
            if pI[p] >= L.rows { pI[p] %= L.rows }
            if pJ[p] >= L.cols { pJ[p] %= L.cols }
            if pU[p] >= perimeter || pU[p] < 0 { pU[p] = pU[p] - (pU[p] / perimeter).rounded(.down) * perimeter }
            let speed = pace * pPace[p]
            let dir = pDir[p]
            switch pWalk[p] {
            case .walking:
                let l = leg(pU[p])
                let end = dir > 0 ? starts[l] + lens[l] : starts[l]
                var u = pU[p] + dir * speed * dt
                pPhase[p] += speed * dt
                if dir > 0 ? u >= end : u <= end {
                    // At a corner: across to the next block, or on round the corner.
                    pCorners[p] &+= 1
                    let w = way(l) * dir
                    let ni = pI[p] + Int(w.x), nj = pJ[p] + Int(w.y)
                    let roll = Float((UInt32(p) &* 2654435761 ^ pCorners[p] &* 40503) % 1000) / 1000
                    if roll < crossShare, ni >= 0, ni < L.rows, nj >= 0, nj < L.cols {
                        pWalk[p] = .waiting
                        pLeg[p] = l
                        u = end
                    }
                }
                pU[p] = u
            case .waiting:
                // Across a street (walking along x) while the avenues have the green, across an
                // avenue while the streets do.
                if (pLeg[p] % 2 == 0) == avenuesGreen { pWalk[p] = .crossing; pT[p] = 0 }
            case .crossing:
                let l = pLeg[p]
                pT[p] += speed * dt
                pPhase[p] += speed * dt
                let across = (l % 2 == 0 ? L.streetW : L.avenueW) + 2 * q
                if pT[p] >= across {
                    let w = way(l) * dir
                    pI[p] += Int(w.x)
                    pJ[p] += Int(w.y)
                    pU[p] = dir > 0 ? starts[l] + 0.01 : starts[l] + lens[l] - 0.01
                    pWalk[p] = .walking
                }
            }

            // Where they are, a little to one side of their way.
            let b = L.blockMin(pI[p], pJ[p])
            var pos: SIMD2<Float>, forward: SIMD2<Float>
            if pWalk[p] == .crossing {
                let l = pLeg[p]
                forward = way(l) * dir
                pos = b + corner(dir > 0 ? (l + 1) % 4 : l) + forward * pT[p]
            } else {
                let l = leg(pU[p])
                forward = way(l) * dir
                pos = b + corner(l) + way(l) * (pU[p] - starts[l])
            }
            pos += SIMD2(-forward.y, forward.x) * pSide[p] * q * 0.8
            out[p] = [pos.x, pos.y, atan2(forward.y, forward.x), pPhase[p]]
        }
    }
}
