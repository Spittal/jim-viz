import Foundation
import Observation
import QuartzCore

/// Per-frame timing, the same for every tool. It carries no tool's data: audio, the beat
/// and colours reach other tools only through mappings.
struct SignalFrame {
    /// Seconds since rendering started, for shaders.
    var time: Float = 0
    var dt: Float = 1.0 / 60
    /// Host time of the frame (`CACurrentMediaTime` scale), for the Clock's tempo tracking.
    var now: CFTimeInterval = 0
}

// MARK: - Waves

/// Shapes shared by the clock and LFOs. All return 0...1.
enum Wave {
    /// 1 on the beat, decaying towards 0.
    static func pulse(_ phase: Double) -> Float { Float(exp(-phase * 6)) }

    static func hash(_ x: Double) -> Float {
        let s = sin(x * 127.1 + 311.7) * 43758.5453
        return Float(s - floor(s))
    }

    /// `x` is in cycles; shapes follow `LFOParams.shapes`. Returns -1...1 (bipolar).
    static func lfo(shape: Int, _ x: Double) -> Float {
        let ph = x - floor(x)
        switch shape {
        case 0: return Float(sin(ph * 2 * .pi))                        // sine
        case 1: return Float(ph < 0.25 ? ph * 4 : (ph < 0.75 ? 2 - ph * 4 : ph * 4 - 4)) // triangle
        case 2: return Float(ph * 2 - 1)                               // saw up
        case 3: return Float(1 - ph * 2)                               // saw down
        case 4: return ph < 0.5 ? 1 : -1                               // square
        case 5: return hash(floor(x)) * 2 - 1                          // random, held per cycle
        default:                                                       // smooth noise
            let i = floor(x), t = Float(x - i)
            let a = hash(i) * 2 - 1, b = hash(i + 1) * 2 - 1
            return a + (b - a) * t * t * (3 - 2 * t)
        }
    }
}

// MARK: - Outputs

/// A signal a tool produces (0...1 for unipolar, -1...1 for bipolar), that mappings
/// can route to any knob in the scene.
/// Keys: `audio.bass`, `clock.pulse`, `mod.lfo.out`, `camera.angle`. Each tool makes its own
/// and computes it from its own state. `compute` runs on the render thread once per frame;
/// `value` is read by the UI meters.
final class OutputSignal: Identifiable {
    let key: String
    let name: String
    /// The device it belongs to, for grouping ("Audio In", "Clock", "lfo2").
    let device: String
    let isBipolar: Bool
    var id: String { key }
    private let compute: (SignalFrame) -> Float
    /// Latest value. Written on the render thread, read by the UI.
    var value: Float = 0

    init(_ key: String, _ name: String, device: String, isBipolar: Bool = false, compute: @escaping (SignalFrame) -> Float) {
        self.key = key; self.name = name; self.device = device; self.isBipolar = isBipolar; self.compute = compute
    }

    func update(_ f: SignalFrame) {
        let raw = compute(f)
        value = isBipolar ? min(max(raw, -1), 1) : min(max(raw, 0), 1)
    }

    /// The device it belongs to, as a chain key: `audio`, `clock`, `mod.lfo`, `camera`.
    var deviceKey: String { devicePath(key) }
}

/// The device part of an output or target key: `audio.kick` → `audio`, `post.glow.amount` → `post.glow`.
func devicePath(_ key: String) -> String {
    key.split(separator: ".").dropLast().joined(separator: ".")
}

enum Outputs {
    /// Display name for a source key, including ones whose device isn't in the scene.
    static func label(_ key: String, in outputs: [OutputSignal]) -> String {
        if let o = outputs.first(where: { $0.key == key }) { return "\(o.device) · \(o.name)" }
        let parts = key.split(separator: ".").map(String.init)
        switch parts.first {
        case "midi" where parts.count == 3: return "MIDI · \(MIDIControl(key: parts[2])?.label ?? parts[2])"
        case "audio": return "Audio In · \(humanize(parts.last ?? key))"
        case "clock": return "Clock · \(humanize(parts.last ?? key))"
        case "mod" where parts.count == 3: return "\(parts[1]) · \(humanize(parts[2]))"
        default: return key
        }
    }
}

// MARK: - MIDI

/// A physical MIDI control: `cc-31-7`, `note-11-1`, `pb-0-1` (kind, number, channel).
/// A MIDI Input device's learned controls are its outputs, keyed `midi.<id>.<control>`.
struct MIDIControl: Hashable {
    enum Kind: String { case cc, note, pb }
    let kind: Kind
    let number: Int
    let channel: Int

    init(kind: Kind, number: Int, channel: Int) { self.kind = kind; self.number = number; self.channel = channel }

    init?(key: String) {
        let p = key.split(separator: "-").map(String.init)
        guard p.count == 3, let k = Kind(rawValue: p[0]), let n = Int(p[1]), let c = Int(p[2]) else { return nil }
        self.init(kind: k, number: n, channel: c)
    }

    init?(_ msg: MIDIMessage) {
        switch msg.command {
        case .controlChange: self.init(kind: .cc, number: msg.data1, channel: msg.channel)
        case .noteOn, .noteOff: self.init(kind: .note, number: msg.data1, channel: msg.channel)
        case .pitchBend: self.init(kind: .pb, number: 0, channel: msg.channel)
        default: return nil
        }
    }

    var key: String { "\(kind.rawValue)-\(number)-\(channel)" }

    /// FLX4 control name when known, otherwise `Ch 7 CC 31`.
    var label: String {
        if let name = MIDIControl.flx4[key] { return name }
        switch kind {
        case .cc: return "Ch \(channel) CC \(number)"
        case .note: return "Ch \(channel) Note \(number)"
        case .pb: return "Ch \(channel) Pitch Bend"
        }
    }

    /// 0...1 value of a message from this control. Notes are 1 while held.
    static func value(_ msg: MIDIMessage) -> Float {
        switch msg.command {
        case .noteOn: return msg.data2 > 0 ? 1 : 0
        case .noteOff: return 0
        default: return msg.normalizedValue
        }
    }

    /// Names of Pioneer DDJ-FLX4 controls, from its Rekordbox MIDI map.
    static let flx4: [String: String] = [
        "cc-31-7": "Crossfader",
        "cc-19-1": "CH1 Fader", "cc-19-2": "CH2 Fader",
        "cc-7-1": "CH1 EQ High", "cc-11-1": "CH1 EQ Mid", "cc-15-1": "CH1 EQ Low",
        "cc-7-2": "CH2 EQ High", "cc-11-2": "CH2 EQ Mid", "cc-15-2": "CH2 EQ Low",
        "cc-4-1": "CH1 Trim", "cc-4-2": "CH2 Trim",
        "cc-23-7": "CH1 CFX", "cc-24-7": "CH2 CFX",
        "cc-0-1": "CH1 Tempo", "cc-0-2": "CH2 Tempo",
        "note-11-1": "CH1 Play", "note-11-2": "CH2 Play",
        "note-12-1": "CH1 Cue", "note-12-2": "CH2 Cue",
    ]
}

/// A MIDI controller in the Inputs section. Each control it has learned is an output
/// holding the control's latest value. Messages arrive on main; the render thread reads.
@Observable
final class MIDIInputRuntime: Identifiable {
    /// Scene id: `midi`, `midi2`…
    let id: String
    /// Device name to listen to; nil listens to every device.
    let device: String?
    let controls: [MIDIControl]
    @ObservationIgnored private(set) var outputs: [OutputSignal] = []
    @ObservationIgnored private var held: [MIDIControl: Held] = [:]
    /// The last control that moved, for the device view.
    private(set) var lastControl: MIDIControl?
    /// While on, each new control moved on its device is handed back by `handle` to be learned.
    /// One input in a scene learns at a time (`RenderScene.learnMIDI`).
    var isLearning = false
    @ObservationIgnored private(set) var lastActivity: CFAbsoluteTime = 0

    final class Held { var value: Float = 0 }

    var key: String { "midi.\(id)" }
    var title: String { device ?? "All MIDI devices" }

    init(id: String, device: String?, controls: [MIDIControl], reuse old: MIDIInputRuntime?) {
        self.id = id; self.device = device; self.controls = controls
        for c in controls {
            let h = old?.held[c] ?? Held()
            held[c] = h
            outputs.append(OutputSignal("midi.\(id).\(c.key)", c.label, device: device ?? "MIDI") { _ in h.value })
        }
        lastControl = old?.lastControl
        lastActivity = old?.lastActivity ?? 0
        isLearning = old?.isLearning ?? false
    }

    func listens(to msg: MIDIMessage) -> Bool { device == nil || msg.device == device }

    /// Main thread. Takes a message from its device. Returns the control and its value when
    /// the control is new and this input is learning, for the scene to add as an output.
    func handle(_ msg: MIDIMessage) -> (MIDIControl, Float)? {
        guard listens(to: msg), let control = MIDIControl(msg) else { return nil }
        let value = MIDIControl.value(msg)
        return receive(control, value) || !isLearning ? nil : (control, value)
    }

    /// Main thread. Returns false if the control isn't one of its outputs yet.
    @discardableResult
    func receive(_ control: MIDIControl, _ value: Float) -> Bool {
        lastActivity = CFAbsoluteTimeGetCurrent()
        if lastControl != control { lastControl = control }
        guard let h = held[control] else { return false }
        h.value = value
        return true
    }
}

// MARK: - Mappings

/// One routing from an output to an input, as edited in the inspector.
///
/// A value mapping (value output → knob) adds `amount × curve(signal) × range` on top of the
/// knob, so the knob stays the base you set by hand; `invert` pushes it down instead.
/// A stream mapping (video, spectrum or palette output → an input of the same kind) just
/// connects the stream; it has no settings.
///
/// UI-facing values are observed; each mirrors into a plain field the render thread reads.
@Observable
final class MappingRuntime: Identifiable {
    let id: String
    let source: String
    let target: String
    let kind: IOKind
    /// Resolved at build. Nil when the device isn't in the scene; the mapping then waits.
    @ObservationIgnored let output: OutputSignal?
    @ObservationIgnored let stream: StreamOutput?
    @ObservationIgnored let param: Param?
    let sourceLabel: String
    let targetLabel: String
    /// Why the mapping is inactive, if it is.
    let problem: String?

    var enabled: Bool { didSet { rEnabled = enabled } }
    /// 0...1: how far the output pushes the knob, as a share of its range.
    var amount: Float { didSet { rAmount = amount } }
    /// Pushes the knob down instead of up.
    var invert: Bool { didSet { rInvert = invert } }
    var smooth: Float { didSet { rSmooth = smooth } }
    var curve: Float { didSet { rCurve = curve } }

    @ObservationIgnored private var rEnabled: Bool
    @ObservationIgnored private var rAmount: Float
    @ObservationIgnored private var rInvert: Bool
    @ObservationIgnored private var rSmooth: Float
    @ObservationIgnored private var rCurve: Float
    @ObservationIgnored private var state: Float = 0
    /// What this mapping adds to its knob this frame, as a fraction of the knob's range
    /// (-1...1): amount × curve(signal), after smoothing. Written on the render thread.
    @ObservationIgnored private(set) var contribution: Float = 0

    var isActive: Bool { problem == nil }

    init(id: String, spec: MappingSpec, kind: IOKind = .value, output: OutputSignal?, stream: StreamOutput? = nil,
         param: Param?, sourceLabel: String, targetLabel: String, problem: String?) {
        self.id = id
        source = spec.source
        target = spec.target
        self.kind = kind
        self.output = output; self.stream = stream; self.param = param
        self.sourceLabel = sourceLabel; self.targetLabel = targetLabel; self.problem = problem
        let e = spec.enabled ?? true, a = spec.amount ?? 0.25, inv = spec.invert ?? false
        let sm = Swift.max(spec.smooth ?? 0, 0), c = Swift.max(spec.curve ?? 1, 0.1)
        rEnabled = e; rAmount = a; rInvert = inv; rSmooth = sm; rCurve = c
        enabled = e; amount = a; invert = inv; smooth = sm; curve = c
    }

    /// The amount with its direction: negative when inverted.
    var signedAmount: Float { invert ? -amount : amount }

    var spec: MappingSpec {
        if kind.isStream { return MappingSpec(source: source, target: target) }
        var s = MappingSpec(source: source, target: target, amount: amount)
        if !enabled { s.enabled = false }
        if invert { s.invert = true }
        if curve != 1 { s.curve = curve }
        if smooth > 0 { s.smooth = smooth }
        return s
    }

    /// Render thread, once per frame, after outputs update.
    func modulate(_ dt: Float) {
        guard rEnabled, let output, let param else { contribution = 0; return }
        var v = output.value
        if rCurve != 1 {
            let s: Float = v < 0 ? -1 : 1
            v = s * pow(abs(v), rCurve)
        }
        if rSmooth > 0 {
            state += (v - state) * (1 - exp(-dt / rSmooth))
            v = state
        }
        contribution = v * (rInvert ? -rAmount : rAmount)
        param.modAccum += contribution * param.def.span
    }
}
