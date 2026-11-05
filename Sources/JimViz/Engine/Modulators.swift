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
        ParamDef(name: "hz", defaultValue: 0.5, min: 0.01, max: 20, isInt: false),
        ParamDef(name: "phase", defaultValue: 0, min: 0, max: 1, isInt: false),
        ParamDef(name: "depth", defaultValue: 1, min: 0, max: 1, isInt: false),
    ]
}

/// A modulator device in the chain (only `lfo` so far). Several can sit side by side.
@Observable
final class ModulatorRuntime: Identifiable {
    let id: String
    let type: String
    let presetLabel: String?
    var enabled: Bool { didSet { rEnabled = enabled } }
    /// Whether this LFO is currently synced to clock via a mapping into `mod.<id>.sync`.
    var isSynced: Bool { didSet { rSynced = isSynced } }
    let bank: ParamBank
    /// Its bipolar output (-1...1), `mod.<id>.out`.
    @ObservationIgnored private(set) var output: OutputSignal!

    @ObservationIgnored private var rEnabled: Bool
    @ObservationIgnored private var rSynced: Bool = false
    /// Free-running phase, integrated so changing `hz` never jumps.
    @ObservationIgnored private var freePhase: Double = 0
    /// Normalized phase (0...1) of the current cycle, read by UI WaveScope.
    @ObservationIgnored var currentPhase: Float = 0

    init(id: String, type: String, presetLabel: String?, enabled: Bool, isSynced: Bool = false, bank: ParamBank) {
        self.id = id; self.type = type; self.presetLabel = presetLabel
        rEnabled = enabled; self.enabled = enabled
        rSynced = isSynced; self.isSynced = isSynced
        self.bank = bank
        output = OutputSignal("mod.\(id).out", "Out", device: id, isBipolar: true) { [unowned self] f in self.value(f) }
    }

    /// Continues a free-running phase from the device this one replaces after a chain edit.
    func continuePhase(from old: ModulatorRuntime) {
        freePhase = old.freePhase
        currentPhase = old.currentPhase
    }

    /// Render thread. Reads knob values from the previous frame, so LFOs can modulate each other.
    private func value(_ f: SignalFrame) -> Float {
        guard rEnabled else {
            currentPhase = 0
            return 0
        }
        let shape = Int(bank.live("shape"))
        let phase = Double(bank.live("phase"))
        let x: Double
        if rSynced {
            let i = Swift.min(Swift.max(Int(bank.live("rate")), 0), LFOParams.rates.count - 1)
            x = f.beat / LFOParams.rates[i].beats
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
