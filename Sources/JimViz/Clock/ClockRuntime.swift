import Foundation
import Observation
import QuartzCore

/// The Clock's knobs, per scene and mappable (`clock.<name>`).
enum ClockParams {
    static let defs: [ParamDef] = [
        /// Shifts the visuals earlier (positive), in ms, to make up for projector and audio delay.
        ParamDef(name: "latency", defaultValue: 0, min: -100, max: 250, isInt: false),
        /// The tempo range audio following searches. Keep it to one octave (max = 2 × min) so
        /// half- and double-time can't be confused.
        ParamDef(name: "minBPM", defaultValue: 90, min: 40, max: 250, isInt: true),
        ParamDef(name: "maxBPM", defaultValue: 180, min: 40, max: 250, isInt: true),
    ]
}

/// The Clock tool in a scene: a beat clock at a typed tempo that follows audio only when Audio
/// In · Audio Out is mapped into its Audio input. Its outputs are the beat as values (Pulse,
/// Beat, Bar, Phrase) and as a Sync stream that LFOs follow when mapped.
///
/// Switching scenes, the incoming Clock picks up the outgoing one's beat and tempo on its first
/// frame, so the beat never jumps. Status is refreshed for the UI at UI rate.
@Observable
final class ClockRuntime {
    let bank: ParamBank
    @ObservationIgnored let manager: ClockManager
    @ObservationIgnored private(set) var outputs: [OutputSignal] = []
    @ObservationIgnored private(set) var syncOutput: StreamOutput!
    /// The Audio In it follows, when mapped. Set when the scene is built.
    @ObservationIgnored private(set) var audioSource: AudioInRuntime?
    /// The previous scene's Clock, whose beat this one takes over on its first frame.
    @ObservationIgnored private var continuing: ClockRuntime?

    /// Whether Audio In · Audio Out is mapped into this Clock.
    private(set) var hearsAudio = false
    private(set) var active: ClockSourceKind = .manual
    private(set) var bpm: Double = 124
    private(set) var beatInBar = 0
    private(set) var bar = 0
    private(set) var audioBPM: Double = 0
    private(set) var audioConfidence: Double = 0
    private(set) var audioUsable = false

    /// `reuse` is this scene's Clock before a chain edit: it keeps running as it was.
    /// `continuing` is another scene's, when switching scenes.
    init(params: [String: Float], reuse old: ClockRuntime?, continuing: ClockRuntime?) {
        bank = ParamBank(defs: ClockParams.defs, values: params, reuse: old?.bank)
        manager = old?.manager ?? ClockManager()
        self.continuing = old == nil ? continuing : nil
        let d = "Clock"
        func out(_ name: String, _ label: String, _ value: @escaping (Double) -> Float) -> OutputSignal {
            OutputSignal("clock.\(name)", label, device: d) { [unowned self] _ in value(self.manager.beat) }
        }
        outputs = [
            out("pulse", "Pulse") { Wave.pulse($0 - floor($0)) },
            out("beat", "Beat Ramp") { Float($0 - floor($0)) },
            out("bar", "Bar Ramp") { let x = $0 / 4; return Float(x - floor(x)) },
            out("phrase", "Phrase Ramp") { let x = $0 / 32; return Float(x - floor(x)) },
        ]
        syncOutput = StreamOutput(StreamOutput.clockSyncKey, "Sync", device: d, kind: .clock)
        refresh()
    }

    /// Continuous beat count. Render thread.
    var beat: Double { manager.beat }

    /// Follows an Audio In's audio, or none. Called when the scene is built, from its mappings.
    func listen(to audio: AudioInRuntime?) {
        audioSource = audio
        hearsAudio = audio != nil
    }

    /// Render thread, once per frame, after Audio In has analysed this frame.
    func advance(_ f: SignalFrame) {
        if let c = continuing {
            manager.continueBeat(from: c.manager)
            continuing = nil
        }
        manager.latencyMs = Double(bank.live("latency"))
        let lo = Double(bank.live("minBPM")), hi = Double(bank.live("maxBPM"))
        manager.audioTempo.minBPM = min(lo, hi)
        manager.audioTempo.maxBPM = max(lo, hi, min(lo, hi) + 1)
        if let a = audioSource, a.analyzer.fresh {
            manager.audioTempo.feed(strength: a.analyzer.onsetStrength, active: a.features.active, time: f.now)
        }
        manager.advance(now: f.now, dt: Double(f.dt), hearsAudio: audioSource != nil)
    }

    /// Main thread, at UI rate. Only assigns when values change, to limit SwiftUI updates.
    func refresh() {
        if active != manager.active { active = manager.active }
        if abs(bpm - manager.bpm) > 0.05 { bpm = manager.bpm }
        let b = max(0, Int(floor(manager.beat)) % 4)
        if b != beatInBar { beatInBar = b }
        let br = max(0, Int(floor(manager.beat / 4)) % 8)
        if br != bar { bar = br }
        let a = manager.audioTempo.status()
        if abs(a.bpm - audioBPM) > 0.05 { audioBPM = a.bpm }
        if abs(a.confidence - audioConfidence) > 0.01 { audioConfidence = a.confidence }
        let usable = hearsAudio && manager.audioTempo.reading(at: CACurrentMediaTime()) != nil
        if usable != audioUsable { audioUsable = usable }
    }

    /// Manual tempo entry.
    func setManualBPM(_ v: Double) { manager.manual.bpm = min(max(v, 40), 250) }

    /// The user pressed First Beat: the beat nearest this moment becomes bar 1, beat 1.
    func firstBeat() { manager.firstBeat(at: CACurrentMediaTime()) }
}
