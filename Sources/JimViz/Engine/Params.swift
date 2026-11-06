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
    /// Set by `rate` on a shader param: a speed. The engine integrates its live value over time
    /// and hands the shader `p.<name>Phase` (= ∫ value dt), so turning the knob changes how fast
    /// things move without jumping, as `time × value` would.
    var isRate = false

    var span: Float { max - min }

    func clamp(_ v: Float) -> Float {
        let c = Swift.min(Swift.max(v, min), max)
        return isInt ? c.rounded() : c
    }

    /// Parses `// @param name default min max [int [Label,Label,…]] [mesh] [rate]` lines from shader source.
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
            let isRate = flags.last == "rate"
            if isRate { flags.removeLast() }
            let rebuildsMesh = flags.last == "mesh"
            if rebuildsMesh { flags.removeLast() }
            let isInt = flags.first == "int"
            // Optional step names after `int`: `// @param mode 0 0 2 int Screen,Faces,Sphere`.
            let labels = isInt && flags.count > 1 ? flags[1].split(separator: ",").map { $0.replacingOccurrences(of: "_", with: " ") } : []
            defs.append(ParamDef(name: name, defaultValue: d, min: lo, max: hi, isInt: isInt,
                                 labels: labels.count == Int(hi - lo) + 1 ? labels : [],
                                 group: currentGroup, requiresInput: currentRequiresInput,
                                 rebuildsMesh: rebuildsMesh, isRate: isRate && !isInt))
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
    /// Rate params: the live value integrated over time (∫ live dt). Render thread.
    @ObservationIgnored var phase: Double = 0

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
/// `unpacked` knobs follow the shader's: the tool reads them itself (a Video's in and out
/// points), so they're left out of the uniforms.
final class ParamBank {
    let params: [Param]
    /// How many of `params`, from the start, are the shader's and packed for it.
    let packedCount: Int
    private let byName: [String: Param]

    init(defs: [ParamDef], unpacked: [ParamDef] = [], values: [String: Float] = [:], reuse: ParamBank? = nil) {
        packedCount = defs.count
        params = (defs + unpacked).map { def in
            // Keep the existing object when the definition is unchanged, so UI state survives reloads.
            if let old = reuse?[def.name], old.def == def {
                if let v = values[def.name] { old.setBase(v) }
                return old
            }
            let carried = reuse?[def.name]
            let p = Param(def: def, value: values[def.name] ?? carried?.base)
            p.phase = carried?.phase ?? 0
            return p
        }
        byName = Dictionary(uniqueKeysWithValues: params.map { ($0.def.name, $0) })
        rateParams = params.filter(\.def.isRate)
        packedRates = params.prefix(packedCount).filter(\.def.isRate)
        packBuffer = [Float](repeating: 0, count: max(packedCount + packedRates.count, 1))
    }

    subscript(name: String) -> Param? { byName[name] }

    func live(_ name: String) -> Float { byName[name]?.live ?? 0 }

    /// Params flagged `rate`, in declaration order.
    let rateParams: [Param]
    /// The shader's rate params, whose phases follow its plain fields.
    private let packedRates: [Param]

    /// The shader's knob definitions, without the tool's own.
    var packedDefs: [ParamDef] { params.prefix(packedCount).map(\.def) }

    /// Scratch for `withPacked`, so packing a bank each frame allocates nothing.
    private var packBuffer: [Float]

    /// Render thread, once per frame after `live` is set: advances every rate param's phase.
    func integrate(dt: Float) {
        for p in rateParams { p.phase += Double(p.live * dt) }
    }

    /// Live values packed to match the generated Metal `Params` struct (one 0 when there are
    /// none): every param in order, then each rate param's phase. As bytes for
    /// `setFragmentBytes`. Render thread only.
    func withPacked(_ body: (UnsafeRawPointer, Int) -> Void) {
        for i in 0..<packedCount { packBuffer[i] = params[i].live }
        for i in packedRates.indices { packBuffer[packedCount + i] = Float(packedRates[i].phase) }
        packBuffer.withUnsafeBytes { body($0.baseAddress!, $0.count) }
    }

    /// Base values for saving back to JSON.
    var baseValues: [String: Float] {
        Dictionary(uniqueKeysWithValues: params.map { ($0.def.name, $0.base) })
    }
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
