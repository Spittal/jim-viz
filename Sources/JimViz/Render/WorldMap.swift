import Foundation
import simd

/// The Globe geo's map: the world's countries, from Natural Earth by way of world-atlas (public
/// domain), read from `Content/Maps/world.json` (made by scripts/make-world-map.py).
/// Neighbouring countries share their border lines (arcs), so simplifying an arc moves both
/// the same way and the countries stay joined at every detail.
/// Loaded once, on main, before the first Globe mesh is built.
enum WorldMap {
    /// One triangle of a country, on the unit sphere.
    struct Triangle {
        var a, b, c: SIMD3<Float>
        /// Bits 0, 1, 2: the edge opposite a, b, c is inside the country, not on its outline.
        var inner: Int
        /// The middle of the triangle's piece of its country (the mainland or an island): the
        /// way the piece faces.
        var centre: SIMD3<Float>
        /// The country's random, 0...1.
        var rand: Float
    }

    private struct File: Decodable {
        /// Border and coast lines, each a flat [lon, lat, lon, lat, …] in degrees.
        let arcs: [[Float]]
        /// Per country, its polygons; per polygon, its rings (the outline, then any holes);
        /// per ring, its arcs in order, ~index for an arc taken backwards.
        let countries: [[[[Int]]]]
    }

    private struct Map {
        var arcs: [[SIMD2<Float>]]
        var countries: [[[[Int]]]]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: Map?
    /// Each detail's triangles, kept once worked out, so sweeping the detail knob is cheap.
    nonisolated(unsafe) private static var cache: [Int: [Triangle]] = [:]

    /// Reads the map unless it's already loaded.
    static func load(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard loaded == nil else { return }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let arcs = try file.arcs.map { f -> [SIMD2<Float>] in
            guard f.count >= 4, f.count % 2 == 0 else { throw CocoaError(.coderInvalidValue) }
            return stride(from: 0, to: f.count, by: 2).map { SIMD2(f[$0], f[$0 + 1]) }
        }
        for polygon in file.countries.joined() {
            guard !polygon.isEmpty, polygon.joined().allSatisfy({ arcs.indices.contains($0 >= 0 ? $0 : ~$0) }) else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        loaded = Map(arcs: arcs, countries: file.countries)
    }

    /// The Globe's `detail` steps (Crude … Fine): how far, in degrees, a simplified border may
    /// stray from the real one. Islands and countries too small to keep a shape drop out.
    static let tolerances: [Float] = [2, 1, 0.5, 0.25, 0.1, 0]

    /// The countries' triangles at a detail step.
    static func triangles(detail: Int) -> [Triangle] {
        let detail = min(max(detail, 0), tolerances.count - 1)
        lock.lock(); defer { lock.unlock() }
        if let done = cache[detail] { return done }
        guard let map = loaded else { return [] }
        let built = build(map, tolerance: tolerances[detail])
        cache[detail] = built
        return built
    }

    /// A point on the unit sphere: north up (+y), longitude 0 facing the front (+x), east to the right.
    static func point(_ lonLat: SIMD2<Float>) -> SIMD3<Float> {
        let lon = lonLat.x * .pi / 180, lat = lonLat.y * .pi / 180
        return SIMD3(cos(lat) * cos(lon), sin(lat), -cos(lat) * sin(lon))
    }

    // MARK: Building

    private static func build(_ map: Map, tolerance: Float) -> [Triangle] {
        // Each arc is simplified once, so both countries along it get the very same points.
        let arcs = map.arcs.map { densify(tolerance > 0 ? simplify($0, tolerance) : $0).map(point) }
        var rng = SplitMix(seed: 0xC0FFEE)
        var out: [Triangle] = []
        for country in map.countries {
            let rand = rng.nextFloat()
            for polygon in country {
                let rings = polygon.map { ring in
                    clean(ring.flatMap { i in (i >= 0 ? arcs[i] : arcs[~i].reversed()).dropLast() })
                }
                if rings[0].isEmpty {
                    // Antarctica: its outline is the south pole and its coast a hole in that.
                    for coast in rings.dropFirst() where !coast.isEmpty {
                        triangulate(coast, holes: [], rand: rand, into: &out)
                    }
                } else {
                    triangulate(rings[0], holes: rings.dropFirst().filter { !$0.isEmpty }, rand: rand, into: &out)
                }
            }
        }
        return out
    }

    /// Douglas-Peucker in degrees, longitude scaled by the cosine of latitude. Keeps both ends.
    private static func simplify(_ pts: [SIMD2<Float>], _ tol: Float) -> [SIMD2<Float>] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let c = cos((pts[a].y + pts[b].y) * 0.5 * .pi / 180)
            let d = (pts[b] - pts[a]) * SIMD2(c, 1), len = simd_length(d)
            var best: Float = 0, bi = -1
            for i in (a + 1)..<b {
                let q = (pts[i] - pts[a]) * SIMD2(c, 1)
                let dist = len > 0 ? abs(q.x * d.y - q.y * d.x) / len : simd_length(q)
                if dist > best { best = dist; bi = i }
            }
            if best > tol {
                keep[bi] = true
                stack.append((a, bi)); stack.append((bi, b))
            }
        }
        return zip(pts, keep).compactMap { $1 ? $0 : nil }
    }

    /// Adds points along stretches longer than 2°, straight in longitude and latitude, so a
    /// border along a parallel stays on it and long edges don't cut through the globe.
    private static func densify(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var out = [pts[0]]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let steps = max(Int((simd_reduce_max(simd_abs(b - a)) / 2).rounded(.up)), 1)
            for k in 1...steps { out.append(k == steps ? b : a + (b - a) * (Float(k) / Float(steps))) }
        }
        return out
    }

    /// A ring without repeated points or spikes that double straight back (Antarctica's pole,
    /// lines simplified flat). Empty when fewer than three points are left.
    private static func clean(_ pts: [SIMD3<Float>]) -> [SIMD3<Float>] {
        func same(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance_squared(a, b) < 1e-12 }
        var s: [SIMD3<Float>] = []
        for p in pts {
            if let last = s.last, same(last, p) { continue }
            if s.count >= 2, same(s[s.count - 2], p) { s.removeLast(); continue }
            s.append(p)
        }
        // The same across the ring's two ends.
        while s.count >= 3 {
            if same(s[0], s[s.count - 1]) || same(s[0], s[s.count - 2]) { s.removeLast() }
            else if same(s[1], s[s.count - 1]) { s.removeFirst() }
            else { break }
        }
        return s.count >= 3 ? s : []
    }

    /// The longest edge a triangle may have, as a squared chord (6°): longer ones are split so
    /// the triangles follow the sphere.
    private static let maxEdge: Float = {
        let chord = 2 * sin(Float(3) * .pi / 180)
        return chord * chord
    }()

    /// Triangulates one piece of a country: flattened around its middle, holes joined to the
    /// outline by a bridge, ears clipped, then split to follow the sphere.
    private static func triangulate(_ outer: [SIMD3<Float>], holes: [[SIMD3<Float>]], rand: Float, into out: inout [Triangle]) {
        let centre = simd_normalize(outer.reduce(.zero, +))
        // Stereographic, about the centre: anything short of the far side of the globe lands on the plane.
        let u = simd_normalize(simd_cross(abs(centre.y) < 0.9 ? [0, 1, 0] : [1, 0, 0], centre)), v = simd_cross(centre, u)
        func flat(_ p: SIMD3<Float>) -> SIMD2<Double> {
            let k = 2 / (1 + simd_dot(p, centre))
            return SIMD2(Double(simd_dot(p, u) * k), Double(simd_dot(p, v) * k))
        }
        func area(_ p: [SIMD2<Double>]) -> Double {
            p.indices.reduce(0) { $0 + cross(.zero, p[$1], p[($1 + 1) % p.count]) }
        }

        // The outline runs anticlockwise, holes clockwise.
        var pts = outer, p2 = outer.map(flat)
        if area(p2) < 0 { pts.reverse(); p2.reverse() }
        var outline = [Bool](repeating: true, count: pts.count)
        for hole in holes {
            var h = hole, h2 = hole.map(flat)
            if area(h2) > 0 { h.reverse(); h2.reverse() }
            // Bridge the hole to the outline from its point nearest the outline, unless that line crosses an edge.
            let bridges = h2.indices.map { hi -> (d: Double, h: Int, o: Int) in
                let oi = p2.indices.min { simd_distance_squared(p2[$0], h2[hi]) < simd_distance_squared(p2[$1], h2[hi]) }!
                return (simd_distance_squared(p2[oi], h2[hi]), hi, oi)
            }.sorted { $0.d < $1.d }
            func crosses(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ ring: [SIMD2<Double>]) -> Bool {
                ring.indices.contains { i in
                    let c = ring[i], d = ring[(i + 1) % ring.count]
                    return cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0
                }
            }
            let bridge = bridges.first { !crosses(h2[$0.h], p2[$0.o], p2) && !crosses(h2[$0.h], p2[$0.o], h2) } ?? bridges[0]
            // Out along the bridge, round the hole, and back: the bridge's two edges aren't outline.
            let order = Array(bridge.h..<h.count) + Array(0...bridge.h)
            let at = bridge.o + 1, back3 = pts[bridge.o], back2 = p2[bridge.o], after = outline[bridge.o]
            pts.insert(contentsOf: order.map { h[$0] } + [back3], at: at)
            p2.insert(contentsOf: order.map { h2[$0] } + [back2], at: at)
            outline[bridge.o] = false
            outline.insert(contentsOf: [Bool](repeating: true, count: h.count) + [false, after], at: at)
        }

        var (tris, edges) = earClip(p2, outline: outline)
        relax(&tris, p2)
        let n = p2.count
        for t in tris {
            let inner = (edges.contains(t.b * n + t.c) ? 0 : 1) | (edges.contains(t.c * n + t.a) ? 0 : 2) | (edges.contains(t.a * n + t.b) ? 0 : 4)
            split(pts[t.a], pts[t.b], pts[t.c], inner, centre: centre, rand: rand, into: &out)
        }
    }

    private static func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Ear clipping. `p` runs anticlockwise; `outline[i]` says whether the edge from point i to
    /// the next is on the country's outline. Returns anticlockwise triangles as indices into
    /// `p`, and the outline's edges as from · count + to. Points sit in a grid so an ear only
    /// checks the points near it.
    private static func earClip(_ p: [SIMD2<Double>], outline: [Bool]) -> (tris: [(a: Int, b: Int, c: Int)], edges: Set<Int>) {
        let n = p.count
        var edges = Set((0..<n).filter { outline[$0] }.map { $0 * n + ($0 + 1) % n })
        var prev = (0..<n).map { ($0 + n - 1) % n }, next = (0..<n).map { ($0 + 1) % n }
        var alive = [Bool](repeating: true, count: n)

        let lo = p.reduce(p[0]) { simd_min($0, $1) }, hi = p.reduce(p[0]) { simd_max($0, $1) }
        let g = max(Int(Double(n).squareRoot()), 1)
        let scale = SIMD2<Double>(repeating: Double(g)) / simd_max(hi - lo, SIMD2(repeating: 1e-12))
        func cell(_ q: SIMD2<Double>) -> (x: Int, y: Int) {
            let c = (q - lo) * scale
            return (min(max(Int(c.x), 0), g - 1), min(max(Int(c.y), 0), g - 1))
        }
        var cells = [[Int]](repeating: [], count: g * g)
        for i in 0..<n {
            let c = cell(p[i])
            cells[c.y * g + c.x].append(i)
        }

        /// Whether another point of the polygon lies in or on the triangle, so it can't be clipped.
        func blocked(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            let pa = p[a], pb = p[b], pc = p[c]
            let from = cell(simd_min(pa, simd_min(pb, pc))), to = cell(simd_max(pa, simd_max(pb, pc)))
            for y in from.y...to.y {
                for x in from.x...to.x {
                    for j in cells[y * g + x] where alive[j] && j != a && j != b && j != c {
                        let q = p[j]
                        if q == pa || q == pb || q == pc { continue }
                        if cross(pa, pb, q) >= 0 && cross(pb, pc, q) >= 0 && cross(pc, pa, q) >= 0 { return true }
                    }
                }
            }
            return false
        }

        var tris: [(a: Int, b: Int, c: Int)] = []
        tris.reserveCapacity(n)
        let flatArea = 1e-12
        var remaining = n, i = 0, misses = 0
        while remaining > 3 {
            let a = prev[i], c = next[i]
            let area = cross(p[a], p[i], p[c])
            let flat = abs(area) <= flatArea
            // A point on a straight line just goes. One reached after a whole turn with no ear
            // (a simplified outline that crosses itself) is clipped anyway.
            guard flat || (area > 0 && !blocked(a, i, c)) || misses >= remaining else {
                misses += 1
                i = c
                continue
            }
            if area > flatArea {
                tris.append((a, i, c))
            } else if flat && edges.contains(a * n + i) && edges.contains(i * n + c) {
                // A point dropped from a straight stretch of outline: the stretch is still outline.
                edges.insert(a * n + c)
            }
            next[a] = c; prev[c] = a; alive[i] = false
            remaining -= 1
            misses = 0
            i = c
        }
        let a = prev[i], c = next[i]
        if cross(p[a], p[i], p[c]) > flatArea { tris.append((a, i, c)) }
        return (tris, edges)
    }

    /// Flips the edge two triangles share wherever one's far corner lies inside the other's
    /// circle, until none does (Delaunay, as far as the outline allows). Ear clipping leaves
    /// needle-thin triangles; this gets rid of most of them.
    private static func relax(_ tris: inout [(a: Int, b: Int, c: Int)], _ p: [SIMD2<Double>]) {
        let n = p.count
        /// Each triangle's edges, from · n + to. An edge inside the polygon has a twin going back.
        var owner: [Int: Int] = [:]
        var stack: [Int] = []
        for (t, tri) in tris.enumerated() {
            for key in [tri.a * n + tri.b, tri.b * n + tri.c, tri.c * n + tri.a] {
                owner[key] = t
                stack.append(key)
            }
        }
        func has(_ t: Int, _ from: Int, _ to: Int) -> Bool {
            let tri = tris[t]
            return (tri.a == from && tri.b == to) || (tri.b == from && tri.c == to) || (tri.c == from && tri.a == to)
        }
        // Points on one circle can flip back and forth through rounding, so there's a limit.
        var budget = tris.count * 8
        while budget > 0, let key = stack.popLast() {
            let u = key / n, v = key % n
            // Both triangles must really have the edge: a simplified outline that crosses itself can leave two claiming one.
            guard let t1 = owner[u * n + v], let t2 = owner[v * n + u], has(t1, u, v), has(t2, v, u) else { continue }
            let w1 = tris[t1].a + tris[t1].b + tris[t1].c - u - v, w2 = tris[t2].a + tris[t2].b + tris[t2].c - u - v
            // w2 inside the circle through u, v, w1.
            let a = p[u] - p[w2], b = p[v] - p[w2], c = p[w1] - p[w2]
            let inside = simd_length_squared(a) * (b.x * c.y - c.x * b.y) - simd_length_squared(b) * (a.x * c.y - c.x * a.y)
                + simd_length_squared(c) * (a.x * b.y - b.x * a.y)
            guard inside > 0, cross(p[w1], p[u], p[w2]) > 1e-12, cross(p[w2], p[v], p[w1]) > 1e-12 else { continue }
            owner[u * n + v] = nil; owner[v * n + u] = nil
            tris[t1] = (w1, u, w2); tris[t2] = (w2, v, w1)
            owner[w1 * n + u] = t1; owner[u * n + w2] = t1; owner[w2 * n + w1] = t1
            owner[w2 * n + v] = t2; owner[v * n + w1] = t2; owner[w1 * n + w2] = t2
            stack += [w1 * n + u, u * n + w2, w2 * n + v, v * n + w1]
            budget -= 1
        }
    }

    /// Splits a triangle across its longest edge until every edge is short enough to follow the
    /// sphere. An edge is always halved at the same point, so neighbouring triangles stay joined.
    private static func split(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ inner: Int,
                              centre: SIMD3<Float>, rand: Float, into out: inout [Triangle]) {
        let ab = simd_distance_squared(a, b), bc = simd_distance_squared(b, c), ca = simd_distance_squared(c, a)
        guard max(ab, bc, ca) > maxEdge else {
            out.append(Triangle(a: a, b: b, c: c, inner: inner, centre: centre, rand: rand))
            return
        }
        // Turn the triangle so its longest edge is a–b; the bits turn with it.
        if bc > ab && bc >= ca {
            return split(b, c, a, (inner >> 1) | ((inner & 1) << 2), centre: centre, rand: rand, into: &out)
        }
        if ca > ab {
            return split(c, a, b, ((inner << 1) & 6) | (inner >> 2), centre: centre, rand: rand, into: &out)
        }
        let m = simd_normalize(a + b)
        // The new edge m–c is inside; the halves of a–b keep its bit (4), the others their own.
        split(a, m, c, 1 | (inner & 2) | (inner & 4), centre: centre, rand: rand, into: &out)
        split(m, b, c, (inner & 1) | 2 | (inner & 4), centre: centre, rand: rand, into: &out)
    }
}

extension MeshBuilder {
    /// Globe: a `facets`-step icosphere of radius 1 (the ocean; shape = 0), then every country
    /// at `detail` as triangles on the unit sphere (shape.w = 1). A country is one face:
    /// its triangles share its random (position.w) and their piece's middle as face normal, so
    /// explode lifts it whole, and bary.w hides the edges inside it from the wireframe.
    mutating func globe(detail: Int, facets: Int) {
        sphere(facets)
        let land = SIMD4<Float>(0, 0, 0, 1)
        for t in WorldMap.triangles(detail: detail) {
            let fn = SIMD4(t.centre, 0), hide = Float(t.inner)
            vertices.append(MeshVertex(position: SIMD4(t.a, t.rand), faceNormal: fn, smoothNormal: SIMD4(t.a, 0), bary: [1, 0, 0, hide], shape: land))
            vertices.append(MeshVertex(position: SIMD4(t.b, t.rand), faceNormal: fn, smoothNormal: SIMD4(t.b, 0), bary: [0, 1, 0, hide], shape: land))
            vertices.append(MeshVertex(position: SIMD4(t.c, t.rand), faceNormal: fn, smoothNormal: SIMD4(t.c, 0), bary: [0, 0, 1, hide], shape: land))
        }
    }
}
