import Foundation
import Observation

/// Knobs of the LFO tool.
enum LFOParams {
    static let shapes = ["Sine", "Triangle", "Saw Up", "Saw Down", "Square", "Random", "Noise"]
    /// Synced periods, in beats, with Ableton-style names.
    static let rates: [(beats: Double, label: String)] = [
        (1.0 / 16.0, "1/64"),
        (1.0 / 8.0, "1/32"),
        (1.0 / 6.0, "1/16T"),
        (0.25, "1/16"),
        (0.375, "1/16D"),
        (1.0 / 3.0, "1/8T"),
        (0.5, "1/8"),
        (0.75, "1/8D"),
        (2.0 / 3.0, "1/4T"),
        (1.0, "1/4"),
        (1.5, "1/4D"),
        (4.0 / 3.0, "1/2T"),
        (2.0, "1/2"),
        (3.0, "1/2D"),
        (4.0, "1 bar"),
        (6.0, "1.5 bars"),
        (8.0, "2 bars"),
        (12.0, "3 bars"),
        (16.0, "4 bars"),
        (24.0, "6 bars"),
        (32.0, "8 bars"),
        (48.0, "12 bars"),
        (64.0, "16 bars"),
        (128.0, "32 bars"),
    ]

    static let defs: [ParamDef] = [
        ParamDef(name: "shape", defaultValue: 0, min: 0, max: Float(shapes.count - 1), isInt: true, labels: shapes),
        ParamDef(name: "rate", defaultValue: 14, min: 0, max: Float(rates.count - 1), isInt: true, labels: rates.map(\.label)),
        ParamDef(name: "hz", defaultValue: 0.5, min: 0, max: 20, isInt: false),
        ParamDef(name: "phase", defaultValue: 0, min: 0, max: 1, isInt: false),
        ParamDef(name: "depth", defaultValue: 1, min: 0, max: 1, isInt: false),
    ]
}

/// Knobs of the Math tool: one value in (`a`, map any output onto it), an operation, and an
/// operand (`b`, a knob too, so a second output mapped there makes it a two-input op).
enum MathParams {
    static let ops = ["A × B", "A + B", "A − B", "|A − B|", "Min", "Max", "Power", "Gate", "Steps", "Fold", "Wrap", "1 − A"]

    static let defs: [ParamDef] = [
        ParamDef(name: "a", defaultValue: 0, min: 0, max: 1, isInt: false),
        ParamDef(name: "op", defaultValue: 0, min: 0, max: Float(ops.count - 1), isInt: true, labels: ops),
        ParamDef(name: "b", defaultValue: 0.5, min: 0, max: 1, isInt: false),
    ]

    /// One operation, 0...1 in and out (before the output clamps). What `b` means per op:
    /// Power: the curve, 0.5 straight, above that sharper (A^8 at 1), below softer (A^⅛ at 0).
    /// Gate: the threshold. Steps: 2 to 16 levels. Fold, Wrap: how many times (1 to 8).
    static func apply(op: Int, _ a: Float, _ b: Float) -> Float {
        switch op {
        case 0: return a * b
        case 1: return a + b
        case 2: return a - b
        case 3: return abs(a - b)
        case 4: return min(a, b)
        case 5: return max(a, b)
        case 6: return pow(max(a, 0), exp2((b - 0.5) * 6))
        case 7: return a > b ? 1 : 0
        case 8:
            let n = 2 + (b * 14).rounded()
            return min(floor(a * n) / (n - 1), 1)
        case 9:
            let x = a * (1 + b * 7) * 0.5
            return 1 - abs((x - floor(x)) * 2 - 1)
        case 10:
            let x = a * (1 + b * 7)
            return x - floor(x)
        default: return 1 - a
        }
    }
}

/// Knobs of the Macro tool: three plain 0...1 knobs, each with its own output, so one knob can
/// drive many others. The knobs are mappable too (a MIDI control or an LFO onto a macro).
enum MacroParams {
    static let count = 3
    static let names = (1...count).map { "macro\($0)" }

    static let defs: [ParamDef] = names.map { ParamDef(name: $0, defaultValue: 0, min: 0, max: 1, isInt: false) }
}

/// The modulator tools.
enum ModulatorType: String {
    /// A low-frequency oscillator: bipolar, free running or synced to a Clock.
    case lfo
    /// Takes one value in through its `a` knob, does some math with `b`, and outputs the result.
    case math
    /// Three knobs, each an output: one knob controls many.
    case macro

    var defs: [ParamDef] {
        switch self {
        case .lfo: return LFOParams.defs
        case .math: return MathParams.defs
        case .macro: return MacroParams.defs
        }
    }

    var label: String {
        switch self {
        case .lfo: return "LFO"
        case .math: return "Math"
        case .macro: return "Macro"
        }
    }
}

/// A modulator device in the chain: an LFO, a Math or a Macro. Several can sit side by side.
@Observable
final class ModulatorRuntime: Identifiable {
    let id: String
    let type: ModulatorType
    let presetLabel: String?
    var enabled: Bool { didSet { rEnabled = enabled } }
    /// Whether Clock · Sync is mapped into its `mod.<id>.sync` input.
    private(set) var isSynced = false
    let bank: ParamBank
    /// Its outputs. LFO and Math have one, `mod.<id>.out`: bipolar (-1...1) for an LFO, 0...1
    /// for Math. A Macro has one per knob, `mod.<id>.macro1`… (0...1).
    @ObservationIgnored private(set) var outputs: [OutputSignal] = []
    /// The first output, which LFO and Math scopes draw.
    var output: OutputSignal { outputs[0] }

    @ObservationIgnored private var rEnabled: Bool
    /// The Clock it follows, through its Sync input. Set when the scene is built.
    @ObservationIgnored private var syncClock: ClockRuntime?
    /// Free-running phase, integrated so changing `hz` never jumps.
    @ObservationIgnored private var freePhase: Double = 0
    /// Normalized phase (0...1) of the current cycle, read by UI WaveScope.
    @ObservationIgnored var currentPhase: Float = 0

    init(id: String, type: ModulatorType, presetLabel: String?, enabled: Bool, bank: ParamBank) {
        self.id = id; self.type = type; self.presetLabel = presetLabel
        rEnabled = enabled; self.enabled = enabled
        self.bank = bank
        switch type {
        case .lfo:
            outputs = [OutputSignal("mod.\(id).out", "Out", device: id, isBipolar: true) { [unowned self] f in self.lfoValue(f) }]
        case .math:
            outputs = [OutputSignal("mod.\(id).out", "Out", device: id) { [unowned self] _ in self.mathValue() }]
        case .macro:
            outputs = MacroParams.names.enumerated().map { i, name in
                OutputSignal("mod.\(id).\(name)", "Macro \(i + 1)", device: id) { [unowned self] _ in self.macroValue(name) }
            }
        }
    }

    /// Render thread. The knob's value as of the previous frame (so mappings onto it count).
    private func macroValue(_ name: String) -> Float {
        rEnabled ? bank.live(name) : 0
    }

    /// Follows a Clock's beat, or runs free (nil). Called when the scene is built, from its mappings.
    func sync(to clock: ClockRuntime?) {
        syncClock = clock
        isSynced = clock != nil
    }

    /// Continues a free-running phase from the device this one replaces after a chain edit.
    func continuePhase(from old: ModulatorRuntime) {
        freePhase = old.freePhase
        currentPhase = old.currentPhase
    }

    /// Render thread. Reads `a` and `b` as of the previous frame, like every modulator, so a
    /// Math one frame behind its input.
    private func mathValue() -> Float {
        guard rEnabled else { return 0 }
        return MathParams.apply(op: Int(bank.live("op")), bank.live("a"), bank.live("b"))
    }

    /// Render thread. Reads knob values from the previous frame, so LFOs can modulate each other.
    private func lfoValue(_ f: SignalFrame) -> Float {
        guard rEnabled else {
            currentPhase = 0
            return 0
        }
        let shape = Int(bank.live("shape"))
        let phase = Double(bank.live("phase"))
        let x: Double
        if let clock = syncClock {
            let i = Swift.min(Swift.max(Int(bank.live("rate")), 0), LFOParams.rates.count - 1)
            x = clock.beat / LFOParams.rates[i].beats
        } else {
            freePhase += Double(f.dt * bank.live("hz"))
            x = freePhase
        }
        let total = x + phase
        let wrapped = total - floor(total)
        currentPhase = Float(wrapped)
        return Wave.lfo(shape: shape, total) * bank.live("depth")
    }
}
