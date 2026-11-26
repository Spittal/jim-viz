import Foundation
import Observation
import QuartzCore

/// Per-frame timing, the same for every tool. It carries no tool's data: audio, the beat
/// and colours reach other tools only through mappings.
struct SignalFrame {
    /// Seconds since rendering started, for shaders.
    var time: Float = 0
    var dt: Float = 1.0 / 60
    /// Host time of the frame (`CACurrentMediaTime` scale), for Audio In's beat.
    var now: CFTimeInterval = 0
}

// MARK: - Waves

/// Shapes shared by the beat and LFOs. All return 0...1.
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
/// Keys: `audio.bass`, `audio.pulse`, `mod.lfo.out`, `camera.angle`. Each tool makes its own
/// and computes it from its own state. `compute` runs on the render thread once per frame;
/// `value` is read by the UI meters.
///
/// A trigger output (`kind` `.trigger`, made with `trigger`) is 1 on the frame its event
/// happens and 0 otherwise; it maps onto trigger inputs only.
final class OutputSignal: Identifiable {
    let key: String
    let name: String
    /// The device it belongs to, for grouping ("Audio In", "lfo2").
    let device: String
    let isBipolar: Bool
    /// `.value` or `.trigger`.
    let kind: IOKind
    var id: String { key }
    private let compute: (SignalFrame) -> Float
    /// Latest value. Written on the render thread, read by the UI.
    var value: Float = 0
    /// Trigger outputs: when it last fired (`SignalFrame.now`), for the UI's flash.
    private(set) var lastFired: CFTimeInterval = -1

    init(_ key: String, _ name: String, device: String, isBipolar: Bool = false, kind: IOKind = .value,
         compute: @escaping (SignalFrame) -> Float) {
        self.key = key; self.name = name; self.device = device; self.isBipolar = isBipolar; self.kind = kind
        self.compute = compute
    }

    /// A trigger output: `fires` runs once per frame on the render thread and says whether the
    /// event happened since the last frame.
    static func trigger(_ key: String, _ name: String, device: String, fires: @escaping (SignalFrame) -> Bool) -> OutputSignal {
        OutputSignal(key, name, device: device, kind: .trigger) { fires($0) ? 1 : 0 }
    }

    func update(_ f: SignalFrame) {
        let raw = compute(f)
        value = isBipolar ? min(max(raw, -1), 1) : min(max(raw, 0), 1)
        if kind == .trigger && value > 0 { lastFired = f.now }
    }

    /// The device it belongs to, as a chain key: `audio`, `mod.lfo`, `camera`.
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
        case "midi" where parts.count == 2: return "MIDI · \(MIDIControl(key: parts[1])?.label ?? parts[1])"
        case "audio": return "Audio In · \(humanize(parts.last ?? key))"
        case "mod" where parts.count == 3: return "\(parts[1]) · \(humanize(parts[2]))"
        default: return key
        }
    }
}

// MARK: - MIDI

/// A physical MIDI control: `cc-31-7`, `note-11-1`, `pb-0-1` (kind, number, channel), from
/// any connected device. As an output it is keyed `midi.<control>` (`MIDIMap`).
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

    /// The control as an output: `midi.cc-27-1`.
    var sourceKey: String { "midi.\(key)" }

    init?(sourceKey: String) {
        guard sourceKey.hasPrefix("midi.") else { return nil }
        self.init(key: String(sourceKey.dropFirst(5)))
    }

    /// Short, for a knob in MIDI map mode: `CC 27`, `Note 25`, `PB`, with the channel when not 1.
    var shortLabel: String {
        let base: String
        switch kind {
        case .cc: base = "CC \(number)"
        case .note: base = "Note \(number)"
        case .pb: base = "PB"
        }
        return channel == 1 ? base : "\(channel)/\(base)"
    }

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

// MARK: - Mappings

/// One routing from an output to an input, as edited in the inspector.
///
/// A value mapping (value output → knob) adds `amount × curve(signal) × range` on top of the
/// knob, so the knob stays the base you set by hand; `invert` pushes it down instead.
/// A stream mapping (video, spectrum or palette output → an input of the same kind) just
/// connects the stream; it has no settings. So does a trigger mapping (a trigger or value
/// output → a trigger input), which fires its input as `TriggerInput` describes.
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
    /// Trigger mappings: the input it fires.
    @ObservationIgnored let trigger: TriggerInput?
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
    /// Trigger mappings: whether the source has dropped low enough to fire again. Off at first,
    /// so a source already high when the scene is built doesn't fire.
    @ObservationIgnored private var armed = false
    /// What this mapping adds to its knob this frame, as a fraction of the knob's range
    /// (-1...1): amount × curve(signal), after smoothing. Written on the render thread.
    @ObservationIgnored private(set) var contribution: Float = 0

    var isActive: Bool { problem == nil }

    init(id: String, spec: MappingSpec, kind: IOKind = .value, output: OutputSignal?, stream: StreamOutput? = nil,
         param: Param?, trigger: TriggerInput? = nil, sourceLabel: String, targetLabel: String, problem: String?) {
        self.id = id
        source = spec.source
        target = spec.target
        self.kind = kind
        self.output = output; self.stream = stream; self.param = param; self.trigger = trigger
        self.sourceLabel = sourceLabel; self.targetLabel = targetLabel; self.problem = problem
        let e = spec.enabled ?? true, a = spec.amount ?? 0.25, inv = spec.invert ?? false
        let sm = Swift.max(spec.smooth ?? 0, 0), c = Swift.max(spec.curve ?? 1, 0.1)
        rEnabled = e; rAmount = a; rInvert = inv; rSmooth = sm; rCurve = c
        enabled = e; amount = a; invert = inv; smooth = sm; curve = c
    }

    /// The amount with its direction: negative when inverted.
    var signedAmount: Float { invert ? -amount : amount }

    var spec: MappingSpec {
        if kind != .value { return MappingSpec(source: source, target: target) }
        var s = MappingSpec(source: source, target: target, amount: amount)
        if !enabled { s.enabled = false }
        if invert { s.invert = true }
        if curve != 1 { s.curve = curve }
        if smooth > 0 { s.smooth = smooth }
        return s
    }

    /// Render thread, once per frame, after outputs update.
    func modulate(_ dt: Float) {
        if let trigger, let output {
            let v = output.value
            if armed && v >= 0.5 { trigger.fire(); armed = false }
            else if v < 0.25 { armed = true }
            return
        }
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
