import Foundation
import Metal
import Observation

/// A spectrum's textures, rotated per upload so the CPU never rewrites one the GPU may still
/// be reading. Made on main when Audio In is built; render thread only after that.
final class SpectrumTextures {
    private let textures: [MTLTexture]
    private var index = 0

    init(_ textures: [MTLTexture]) { self.textures = textures }

    var current: MTLTexture { textures[index] }

    func upload(_ bins: [Float]) {
        index = (index + 1) % textures.count
        bins.withUnsafeBytes { raw in
            textures[index].replace(region: MTLRegionMake2D(0, 0, bins.count, 1), mipmapLevel: 0,
                                    withBytes: raw.baseAddress!, bytesPerRow: bins.count * 4)
        }
    }
}

/// The Audio In tool in a scene. It listens to its source (the scene's `device` and
/// `channelPair`, through a capture shared with other scenes on that source) and analyses it with its own knobs
/// (`AudioParams`, mappable as `audio.<name>`) and offers what it hears as outputs: band levels
/// and hits (values), Spectrum and Audio Out (streams), the harmonic/percussive split (Harmonic and
/// Percussive levels and spectra), and the beat.
///
/// The beat comes from the source's beat tracker through a `BeatClock`, as values (Pulse, Beat,
/// Bar and Phrase ramps), triggers (On Beat, On Bar, On Phrase) and a Sync stream that LFOs and
/// shaders' rate knobs follow when mapped. Its First Beat trigger input sets the downbeat.
/// Analysis runs on the render thread once per frame, only while its scene is drawn; switching
/// scenes, the incoming Audio In picks up the outgoing one's levels (same source) and beat.
@Observable
final class AudioInRuntime {
    /// The source it listens to, shared by every scene's Audio In on that source.
    let capture: AudioCapture
    let bank: ParamBank
    /// Levels for the device view, refreshed at UI rate.
    let meters = AudioMeters()
    @ObservationIgnored let analyzer: AudioAnalyzer
    @ObservationIgnored let spectrum: SpectrumTextures
    @ObservationIgnored let harmonicSpectrum: SpectrumTextures
    @ObservationIgnored let percussiveSpectrum: SpectrumTextures
    @ObservationIgnored private(set) var outputs: [OutputSignal] = []
    @ObservationIgnored private(set) var spectrumOutput: StreamOutput!
    @ObservationIgnored private(set) var audioOutput: StreamOutput!
    @ObservationIgnored private(set) var syncOutput: StreamOutput!
    /// The beat. Kept across chain edits.
    @ObservationIgnored let clock: BeatClock
    /// `audio.firstBeat`: each fire is a press of First Beat, at the moment it fired.
    @ObservationIgnored let firstBeatTrigger = TriggerInput("audio.firstBeat", "First Beat")
    @ObservationIgnored private(set) var harmonicSpectrumOutput: StreamOutput!
    @ObservationIgnored private(set) var percussiveSpectrumOutput: StreamOutput!
    /// This frame's analysis. Render thread.
    @ObservationIgnored var features = AudioFeatures()
    /// Smoothed loudness and activity, for the Intensity output. Render thread.
    @ObservationIgnored private var intensity: Float = 0
    /// The previous scene's Audio In, whose analysis and beat this one takes over on its first frame.
    @ObservationIgnored private var continuing: AudioInRuntime?
    /// Whether `continuing` listens to the same source, so its analysis carries over too.
    @ObservationIgnored private var continuingSameSource = false

    // The beat, for the UI, refreshed at UI rate.
    private(set) var bpm: Double = 0
    private(set) var confidence: Double = 0
    private(set) var barKnown = false
    private(set) var beatInBar = 0
    private(set) var bar = 0

    /// `reuse` is this scene's Audio In before a chain edit: its knobs carry over, and its
    /// analysis too if it listens to the same capture. `continuing` is another scene's, when
    /// switching scenes; its analysis carries over only from the same capture.
    /// `makeSpectrum` makes a spectrum's textures, for those `reuse` doesn't bring.
    init(capture: AudioCapture, params: [String: Float], makeSpectrum: () -> SpectrumTextures,
         reuse old: AudioInRuntime?, continuing: AudioInRuntime?) {
        self.capture = capture
        bank = ParamBank(defs: AudioParams.defs, values: params, reuse: old?.bank)
        let same = old.map { $0.capture === capture } ?? false
        analyzer = same ? old!.analyzer : AudioAnalyzer()
        spectrum = old?.spectrum ?? makeSpectrum()
        harmonicSpectrum = old?.harmonicSpectrum ?? makeSpectrum()
        percussiveSpectrum = old?.percussiveSpectrum ?? makeSpectrum()
        clock = old?.clock ?? BeatClock()
        self.continuing = old == nil ? continuing : nil
        continuingSameSource = continuing?.capture === capture
        intensity = same ? old!.intensity : (continuingSameSource ? continuing?.intensity : nil) ?? 0
        let d = "Audio In"
        func out(_ name: String, _ label: String, _ value: @escaping (AudioFeatures) -> Float) -> OutputSignal {
            OutputSignal("audio.\(name)", label, device: d) { [unowned self] _ in value(self.features) }
        }
        outputs = [
            out("bass", "Bass") { $0.bass },
            out("mid", "Mid") { $0.mid },
            out("high", "High") { $0.high },
            out("level", "Level") { $0.level },
            out("kick", "Kick") { $0.kick },
            out("snare", "Snare") { $0.snare },
            out("hat", "Hat") { $0.hat },
            out("harmonic", "Harmonic") { $0.harmonic },
            out("percussive", "Percussive") { $0.percussive },
            // How hard the music is going right now: loudness, bass and hit activity, smoothed
            // over about 1.5 seconds, so it rises into drops and falls away in breakdowns.
            OutputSignal("audio.intensity", "Intensity", device: d) { [unowned self] f in
                let a = self.features
                let hits = min((a.kick + a.snare + a.hat) / 1.5, 1)
                let target = min(a.level * 0.45 + a.bass * 0.3 + hits * 0.35, 1)
                self.intensity += (target - self.intensity) * (1 - exp(-f.dt / 1.5))
                return self.intensity
            },
        ]
        func beatOut(_ name: String, _ label: String, _ value: @escaping (Double) -> Float) -> OutputSignal {
            OutputSignal("audio.\(name)", label, device: d) { [unowned self] _ in value(self.clock.beat) }
        }
        outputs += [
            beatOut("pulse", "Pulse") { Wave.pulse($0 - floor($0)) },
            beatOut("beat", "Beat Ramp") { Float($0 - floor($0)) },
            beatOut("bar", "Bar Ramp") { let x = $0 / 4; return Float(x - floor(x)) },
            beatOut("phrase", "Phrase Ramp") { let x = $0 / 32; return Float(x - floor(x)) },
            every(1, "onBeat", "On Beat"),
            every(4, "onBar", "On Bar"),
            every(32, "onPhrase", "On Phrase"),
        ]
        func spectrumOut(_ key: String, _ textures: SpectrumTextures) -> StreamOutput {
            StreamOutput(key, StreamOutput.spectrumNames[key]!, device: d, kind: .spectrum) { textures.current }
        }
        spectrumOutput = spectrumOut(StreamOutput.spectrumKey, spectrum)
        audioOutput = StreamOutput(StreamOutput.audioKey, "Audio Out", device: d, kind: .audio)
        syncOutput = StreamOutput(StreamOutput.syncKey, "Sync", device: d, kind: .clock)
        harmonicSpectrumOutput = spectrumOut(StreamOutput.harmonicSpectrumKey, harmonicSpectrum)
        percussiveSpectrumOutput = spectrumOut(StreamOutput.percussiveSpectrumKey, percussiveSpectrum)
    }

    var streamOutputs: [StreamOutput] { [spectrumOutput, audioOutput, harmonicSpectrumOutput, percussiveSpectrumOutput, syncOutput] }

    /// A trigger output that fires each time the beat count crosses a multiple of `beats`.
    private func every(_ beats: Double, _ name: String, _ label: String) -> OutputSignal {
        var last = Double.nan
        return OutputSignal.trigger("audio.\(name)", label, device: "Audio In") { [unowned self] _ in
            let n = floor(self.clock.beat / beats)
            defer { last = n }
            return n != last && !last.isNaN
        }
    }

    /// Continuous beat count. Render thread.
    var beat: Double { clock.beat }

    /// Render thread, once per frame, before anything reads its outputs: analyses the latest
    /// audio and advances the beat.
    func process(_ f: SignalFrame) {
        if let c = continuing {
            if continuingSameSource { analyzer.continueState(from: c.analyzer) }
            clock.continueBeat(from: c.clock)
            continuing = nil
        }
        let dt = f.dt
        analyzer.process(ring: capture.ring, dt: dt, settings: bank)
        features = analyzer.features
        spectrum.upload(analyzer.spectrum.bins)
        harmonicSpectrum.upload(analyzer.harmonicSpectrum.bins)
        percussiveSpectrum.upload(analyzer.percussiveSpectrum.bins)

        if firstBeatTrigger.take() { clock.firstBeat(at: firstBeatTrigger.lastFired) }
        clock.latencyMs = Double(bank.live("latency"))
        let lo = Double(bank.live("minBPM")), hi = Double(bank.live("maxBPM"))
        capture.beats.demand(minBPM: min(lo, hi), maxBPM: max(lo, hi, min(lo, hi) + 1))
        clock.advance(now: f.now, dt: Double(dt), source: capture.beats)
    }

    /// The user pressed First Beat: the beat nearest this moment becomes bar 1, beat 1.
    func firstBeat() { firstBeatTrigger.fire() }

    /// Main thread, at UI rate. Only assigns when values change, to limit SwiftUI updates.
    func refresh() {
        meters.update(from: analyzer)
        let s = capture.beats.status()
        let shown = clock.bpm
        if abs(shown - bpm) > 0.05 { bpm = shown }
        if abs(s.confidence - confidence) > 0.01 { confidence = s.confidence }
        if s.barKnown != barKnown { barKnown = s.barKnown }
        let b = max(0, Int(floor(clock.beat)) % 4)
        if b != beatInBar { beatInBar = b }
        let br = max(0, Int(floor(clock.beat / 4)) % 8)
        if br != bar { bar = br }
    }
}
