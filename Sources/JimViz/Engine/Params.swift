import Foundation
import simd
import Observation

/// Describes one tweakable value: its name, default and range.
struct ParamDef: Hashable {
    let name: String
    let defaultValue: Float
    let min: Float
    let max: Float
    let isInt: Bool
    /// Names for each step of an int param (`shape`: Sine, Triangle…), shown instead of the number.
    var labels: [String] = []
    /// Category / group name for organizing knobs with visual separation.
    var group: String? = nil
    /// Stream input key required for this param to be relevant (e.g. `texVideo`, `spec`).
    var requiresInput: String? = nil
    /// Set by `mesh` on a generator param: it changes the triangle count (torus sides, wheel
    /// blades), so the mesh is rebuilt when its value changes.
    var rebuildsMesh = false

    var span: Float { max - min }

    func clamp(_ v: Float) -> Float {
        let c = Swift.min(Swift.max(v, min), max)
        return isInt ? c.rounded() : c
    }

    /// Parses `// @param name default min max [int [Label,Label,…]] [mesh]` lines from shader source.
    static func parse(shaderSource: String) -> [ParamDef] {
        var defs: [ParamDef] = []
        var currentGroup: String? = nil
        var currentRequiresInput: String? = nil
        for raw in shaderSource.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("// @group ") {
                let parts = line.dropFirst("// @group ".count).split(separator: " ").map(String.init)
                currentGroup = parts.first
                currentRequiresInput = parts.count > 1 ? parts[1] : nil
                continue
            }
            guard line.hasPrefix("// @param ") else { continue }
            let parts = line.dropFirst("// @param ".count).split(separator: " ").map(String.init)
            guard parts.count >= 4,
                  let d = Float(parts[1]), let lo = Float(parts[2]), let hi = Float(parts[3]) else { continue }
            let name = parts[0]
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  !defs.contains(where: { $0.name == name }) else { continue }
            var flags = Array(parts.dropFirst(4))
            let rebuildsMesh = flags.last == "mesh"
            if rebuildsMesh { flags.removeLast() }
            let isInt = flags.first == "int"
            // Optional step names after `int`: `// @param mode 0 0 2 int Screen,Faces,Sphere`.
            let labels = isInt && flags.count > 1 ? flags[1].split(separator: ",").map { $0.replacingOccurrences(of: "_", with: " ") } : []
            defs.append(ParamDef(name: name, defaultValue: d, min: lo, max: hi, isInt: isInt,
                                 labels: labels.count == Int(hi - lo) + 1 ? labels : [],
                                 group: currentGroup, requiresInput: currentRequiresInput,
                                 rebuildsMesh: rebuildsMesh))
        }
        return defs
    }
}

/// A live parameter shared between the UI (main thread) and the render thread.
///
/// The UI writes `base` through `setBase`. The render thread reads `liveBase`, applies
/// modulation, and writes `live`. The UI refreshes `display` from `live` at a low rate.
/// Plain Float fields are read across threads without locking; a torn read is impossible
/// for 32-bit values and a one-frame-stale value is harmless.
@Observable
final class Param: Identifiable {
    let def: ParamDef
    var id: String { def.name }

    private(set) var base: Float
    /// Modulated value as last shown in the UI.
    var display: Float
    /// True when at least one active modulation mapping targets this param.
    var isModulated = false

    @ObservationIgnored var liveBase: Float
    @ObservationIgnored var live: Float
    @ObservationIgnored var modAccum: Float = 0

    init(def: ParamDef, value: Float? = nil) {
        self.def = def
        let v = def.clamp(value ?? def.defaultValue)
        base = v
        display = v
        liveBase = v
        live = v
    }

    func setBase(_ v: Float) {
        let c = def.clamp(v)
        guard c != base else { return }
        base = c
        liveBase = c
        if !isModulated { display = c; live = c }
    }

    func reset() { setBase(def.defaultValue) }
}

/// An ordered set of params, packed in declaration order for shader uniforms.
final class ParamBank {
    let params: [Param]
    private let byName: [String: Param]

    init(defs: [ParamDef], values: [String: Float] = [:], reuse: ParamBank? = nil) {
        params = defs.map { def in
            // Keep the existing object when the definition is unchanged, so UI state survives reloads.
            if let old = reuse?[def.name], old.def == def {
                if let v = values[def.name] { old.setBase(v) }
                return old
            }
            let carried = reuse?[def.name]?.base
            return Param(def: def, value: values[def.name] ?? carried)
        }
        byName = Dictionary(uniqueKeysWithValues: params.map { ($0.def.name, $0) })
        packBuffer = [Float](repeating: 0, count: max(params.count, 1))
    }

    subscript(name: String) -> Param? { byName[name] }

    func live(_ name: String) -> Float { byName[name]?.live ?? 0 }

    /// Scratch for `withPacked`, so packing a bank each frame allocates nothing.
    private var packBuffer: [Float]

    /// Live values packed to match the generated Metal `Params` struct (one 0 when there are
    /// none), as bytes for `setFragmentBytes`. Render thread only.
    func withPacked(_ body: (UnsafeRawPointer, Int) -> Void) {
        for i in params.indices { packBuffer[i] = params[i].live }
        packBuffer.withUnsafeBytes { body($0.baseAddress!, $0.count) }
    }

    /// Base values for saving back to JSON.
    var baseValues: [String: Float] {
        Dictionary(uniqueKeysWithValues: params.map { ($0.def.name, $0.base) })
    }
}

enum CameraParams {
    static let defs: [ParamDef] = [
        ParamDef(name: "distance", defaultValue: 6, min: 0.5, max: 40, isInt: false),
        ParamDef(name: "height", defaultValue: 1, min: -15, max: 15, isInt: false),
        ParamDef(name: "orbitSpeed", defaultValue: 0.15, min: -3, max: 3, isInt: false),
        // 0 orbits all the way round; above 0 the camera swings back and forth this many
        // degrees either side of the front (+x) instead, for things meant to be seen face-on.
        ParamDef(name: "swing", defaultValue: 0, min: 0, max: 180, isInt: false),
        ParamDef(name: "fov", defaultValue: 55, min: 10, max: 150, isInt: false),
        ParamDef(name: "roll", defaultValue: 0, min: -180, max: 180, isInt: false),
        ParamDef(name: "rollSpeed", defaultValue: 0, min: -2, max: 2, isInt: false),
        ParamDef(name: "lookY", defaultValue: 0, min: -10, max: 10, isInt: false),
        ParamDef(name: "shake", defaultValue: 0, min: 0, max: 1, isInt: false),
        ParamDef(name: "sway", defaultValue: 0.2, min: 0, max: 2, isInt: false),
    ]
}

/// The palette's inputs: adjustments applied to every colour, so they can be mapped
/// (a kick flashing brightness, an LFO drifting hue).
enum PaletteParams {
    static let defs: [ParamDef] = [
        ParamDef(name: "red", defaultValue: 1, min: 0, max: 2, isInt: false),
        ParamDef(name: "green", defaultValue: 1, min: 0, max: 2, isInt: false),
        ParamDef(name: "blue", defaultValue: 1, min: 0, max: 2, isInt: false),
        ParamDef(name: "hue", defaultValue: 0, min: -180, max: 180, isInt: false),
        ParamDef(name: "saturation", defaultValue: 1, min: 0, max: 2, isInt: false),
        ParamDef(name: "brightness", defaultValue: 1, min: 0, max: 2, isInt: false),
    ]

    /// Applies the adjustments to one colour: RGB gains, then hue rotation, saturation, brightness.
    static func adjust(_ c: SIMD3<Float>, value v: (String) -> Float) -> SIMD3<Float> {
        var c = c * SIMD3(v("red"), v("green"), v("blue"))
        let hue = v("hue")
        if hue != 0 {
            // Rotation about the grey axis.
            let a = hue * .pi / 180, cosA = cos(a), sinA = sin(a), k = (1 - cosA) / 3, s = sinA / Float(3).squareRoot()
            let m0 = cosA + k, m1 = k - s, m2 = k + s
            c = SIMD3(c.x * m0 + c.y * m1 + c.z * m2, c.x * m2 + c.y * m0 + c.z * m1, c.x * m1 + c.y * m2 + c.z * m0)
        }
        let l = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        c = SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * v("saturation")
        return simd_max(c * v("brightness"), .zero)
    }
}
