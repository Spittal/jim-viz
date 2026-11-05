import Foundation
import Observation

/// Knobs of the LFO tool.
enum LFOParams {
    static let shapes = ["Sine", "Triangle", "Saw Up", "Saw Down", "Square", "Random", "Noise"]
    /// Synced periods, in beats, with Ableton-style names.
    static let rates: [(beats: Double, label: String)] = [
        (0.25, "1/16"), (0.5, "1/8"), (1, "1/4"), (2, "1/2"), (4, "1 bar"),
        (8, "2 bars"), (16, "4 bars"), (32, "8 bars"), (64, "16 bars"),
    ]

    static let defs: [ParamDef] = [
        ParamDef(name: "shape", defaultValue: 0, min: 0, max: Float(shapes.count - 1), isInt: true, labels: shapes),
        ParamDef(name: "sync", defaultValue: 1, min: 0, max: 1, isInt: true, labels: ["Free", "Sync"]),
        ParamDef(name: "rate", defaultValue: 4, min: 0, max: Float(rates.count - 1), isInt: true, labels: rates.map(\.label)),
        ParamDef(name: "hz", defaultValue: 0.5, min: 0.01, max: 10, isInt: false),
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
    let bank: ParamBank
    /// Its output, `mod.<id>.out`.
    @ObservationIgnored private(set) var output: OutputSignal!

    @ObservationIgnored private var rEnabled: Bool
    /// Free-running phase, integrated so changing `hz` never jumps.
    @ObservationIgnored private var freePhase: Double = 0

    init(id: String, type: String, presetLabel: String?, enabled: Bool, bank: ParamBank) {
        self.id = id; self.type = type; self.presetLabel = presetLabel
        rEnabled = enabled; self.enabled = enabled; self.bank = bank
        output = OutputSignal("mod.\(id).out", "Out", device: id) { [unowned self] f in self.value(f) }
    }

    /// Continues a free-running phase from the device this one replaces after a chain edit.
    func continuePhase(from old: ModulatorRuntime) { freePhase = old.freePhase }

    /// Render thread. Reads knob values from the previous frame, so LFOs can modulate each other.
    private func value(_ f: SignalFrame) -> Float {
        guard rEnabled else { return 0 }
        let shape = Int(bank.live("shape"))
        let phase = Double(bank.live("phase"))
        let x: Double
        if bank.live("sync") >= 0.5 {
            let i = Swift.min(Swift.max(Int(bank.live("rate")), 0), LFOParams.rates.count - 1)
            x = f.beat / LFOParams.rates[i].beats
        } else {
            freePhase += Double(f.dt * bank.live("hz"))
            x = freePhase
        }
        return Wave.lfo(shape: shape, x + phase) * bank.live("depth")
    }
}
