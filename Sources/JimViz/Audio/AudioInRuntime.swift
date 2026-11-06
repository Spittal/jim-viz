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
/// (`AudioParams`: range, release, sensitivity, gate, mappable as `audio.<name>`) and offers
/// what it hears as outputs: band levels and hits (values), Spectrum and Audio Out (streams),
/// and the harmonic/percussive split (Harmonic and Percussive levels and spectra).
/// Analysis runs on the render thread once per frame, only while its scene is drawn.
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
    @ObservationIgnored private(set) var harmonicSpectrumOutput: StreamOutput!
    @ObservationIgnored private(set) var percussiveSpectrumOutput: StreamOutput!
    /// This frame's analysis. Render thread.
    @ObservationIgnored var features = AudioFeatures()
    /// Smoothed loudness and activity, for the Intensity output. Render thread.
    @ObservationIgnored private var intensity: Float = 0
    /// The previous scene's Audio In, whose analysis this one takes over on its first frame.
    @ObservationIgnored private var continuing: AudioInRuntime?

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
        let from = old == nil && continuing?.capture === capture ? continuing : nil
        self.continuing = from
        intensity = same ? old!.intensity : from?.intensity ?? 0
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
        func spectrumOut(_ key: String, _ textures: SpectrumTextures) -> StreamOutput {
            StreamOutput(key, StreamOutput.spectrumNames[key]!, device: d, kind: .spectrum) { textures.current }
        }
        spectrumOutput = spectrumOut(StreamOutput.spectrumKey, spectrum)
        audioOutput = StreamOutput(StreamOutput.audioKey, "Audio Out", device: d, kind: .audio)
        harmonicSpectrumOutput = spectrumOut(StreamOutput.harmonicSpectrumKey, harmonicSpectrum)
        percussiveSpectrumOutput = spectrumOut(StreamOutput.percussiveSpectrumKey, percussiveSpectrum)
    }

    var streamOutputs: [StreamOutput] { [spectrumOutput, audioOutput, harmonicSpectrumOutput, percussiveSpectrumOutput] }

    /// Render thread, once per frame, before anything reads its outputs.
    func process(dt: Float) {
        if let c = continuing {
            analyzer.continueState(from: c.analyzer)
            continuing = nil
        }
        analyzer.process(ring: capture.ring, dt: dt, settings: bank)
        features = analyzer.features
        spectrum.upload(analyzer.spectrum.bins)
        harmonicSpectrum.upload(analyzer.harmonicSpectrum.bins)
        percussiveSpectrum.upload(analyzer.percussiveSpectrum.bins)
    }

    /// Main thread, at UI rate.
    func refreshMeters() { meters.update(from: analyzer) }
}
