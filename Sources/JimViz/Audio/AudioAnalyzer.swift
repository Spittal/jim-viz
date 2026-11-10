import Accelerate
import Foundation
import os

/// Values produced each frame, all 0...1.
struct AudioFeatures {
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var level: Float = 0
    /// Onset envelopes: jump to 1 on a detected hit, then decay.
    var kick: Float = 0
    var snare: Float = 0
    var hat: Float = 0
    /// Levels of the harmonic (sustained, tonal) and percussive (hits, noise) parts.
    var harmonic: Float = 0
    var percussive: Float = 0
    /// Levels of the separated stems, in `StemSeparator.Stem` order, each relative to the whole
    /// mix's recent peak (1 only when the stem is the mix); 0 while not separating.
    var stems = SIMD4<Float>()
    /// True when there is signal above the gate.
    var active = false
}

/// Audio In's knobs, per scene and mappable (`audio.<name>`): analysis settings, then the beat's.
enum AudioParams {
    static let analysis: [ParamDef] = [
        ParamDef(name: "range", defaultValue: 30, min: 6, max: 60, isInt: false),
        ParamDef(name: "release", defaultValue: 0.12, min: 0, max: 1, isInt: false),
        ParamDef(name: "sensitivity", defaultValue: 0.5, min: 0, max: 1, isInt: false),
        ParamDef(name: "gate", defaultValue: -50, min: -90, max: -20, isInt: false),
    ]
    static let beat: [ParamDef] = [
        /// Shifts the visuals earlier (positive), in ms, to make up for projector and audio delay.
        ParamDef(name: "latency", defaultValue: 0, min: -100, max: 250, isInt: false),
        /// The tempo range beat tracking searches. One octave (max = 2 × min) keeps half- and
        /// double-time from being confused. Shared by scenes listening to the same source.
        ParamDef(name: "minBPM", defaultValue: 90, min: 40, max: 250, isInt: true),
        ParamDef(name: "maxBPM", defaultValue: 180, min: 40, max: 250, isInt: true),
    ]
    static let defs = analysis + beat
    static let beatNames = Set(beat.map(\.name))
}

/// FFT analysis, run on the render thread once per frame on the latest audio window.
///
/// Levels are auto-gained in dB: each band tracks its recent peak (which falls slowly), and
/// the output is 1 at that peak and 0 at `range` dB below it. Quiet breakdowns and loud drops
/// both use the full 0...1 range, so mappings behave the same at any volume.
final class AudioAnalyzer {
    static let fftSize = 2048
    static let spectrumBins = 128

    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var stemPower: [Float]
    private var lastWritten = 0

    private(set) var features = AudioFeatures()
    /// True when this frame analysed new audio.
    private(set) var fresh = false
    /// Log-spaced spectra, 0...1, for shaders: the whole signal, and its harmonic and
    /// percussive parts.
    private(set) var spectrum = LogSpectrum()
    private(set) var harmonicSpectrum = LogSpectrum()
    private(set) var percussiveSpectrum = LogSpectrum()
    /// The separated stems' spectra, in `StemSeparator.Stem` order.
    private(set) var stemSpectra = [LogSpectrum](repeating: LogSpectrum(), count: 4)
    /// This frame's power spectrum split into harmonic and percussive parts.
    private(set) var split = HarmonicPercussive(bins: fftSize / 2)
    private var uiLock = os_unfair_lock()
    private var uiFeatures = AudioFeatures()
    private var uiSpectrum = [Float](repeating: 0, count: spectrumBins)

    /// Thread-safe copy for the UI.
    func snapshot() -> (AudioFeatures, [Float]) {
        os_unfair_lock_lock(&uiLock); defer { os_unfair_lock_unlock(&uiLock) }
        return (uiFeatures, uiSpectrum)
    }

    // Auto-gain and envelope state per band: bass, mid, high, level, harmonic, percussive, then
    // the four stems, whose auto-gain is shared: the whole mix's peak (`peaks[6]`).
    private var peaks: [Float] = Array(repeating: -40, count: 7)
    private var envelopes: [Float] = Array(repeating: 0, count: 10)
    private var onsetDt: Float = 0
    private var onsets: [OnsetDetector] = [
        OnsetDetector(refractory: 0.11, decay: 0.16),  // kick
        OnsetDetector(refractory: 0.09, decay: 0.12),  // snare/clap
        OnsetDetector(refractory: 0.05, decay: 0.06),  // hats
    ]

    init() {
        let n = Self.fftSize
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
        stemPower = power
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Picks up another analyzer's auto-gain, envelopes and onset state, so a scene's Audio In
    /// continues where the previous scene's left off instead of re-learning levels. Render thread.
    func continueState(from other: AudioAnalyzer) {
        peaks = other.peaks
        envelopes = other.envelopes
        spectrum = other.spectrum
        harmonicSpectrum = other.harmonicSpectrum
        percussiveSpectrum = other.percussiveSpectrum
        stemSpectra = other.stemSpectra
        split = other.split
        onsets = other.onsets
        onsetDt = other.onsetDt
        features = other.features
        lastWritten = other.lastWritten
    }

    /// Analyzes the latest window, and the stems' if `stems` is separating. `settings` holds
    /// live values of `AudioParams`.
    func process(ring: SampleRing, stems: LiveStems?, dt: Float, settings: ParamBank?) {
        let range = settings?.live("range") ?? 30
        let release = settings?.live("release") ?? 0.12
        let sensitivity = settings?.live("sensitivity") ?? 0.5
        let gate = settings?.live("gate") ?? -50

        let n = Self.fftSize
        let written = ring.copyLatest(into: &samples, count: n)
        let fresh = written != lastWritten
        lastWritten = written
        let rate = Float(ring.sampleRate)

        // Time-domain level.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        let levelDb = 20 * log10(rms + 1e-9)

        powerSpectrum(of: &samples, into: &power)

        let binHz = rate / Float(n)
        func bandDb(_ lo: Float, _ hi: Float, of power: [Float], binHz: Float = binHz) -> Float {
            let a = max(1, Int(lo / binHz)), b = min(n / 2 - 1, max(a, Int(hi / binHz)))
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + a, 1, &sum, vDSP_Length(b - a + 1)) }
            return 10 * log10(sum + 1e-12)
        }
        func bandDb(_ lo: Float, _ hi: Float) -> Float { bandDb(lo, hi, of: power) }

        let active = levelDb > gate
        let decayPerSec: Float = 2.5 // dB per second the auto-gain peak falls
        func autoGain(_ i: Int, _ db: Float) -> Float {
            peaks[i] = max(db, peaks[i] - decayPerSec * dt, gate + range)
            return active ? min(max((db - (peaks[i] - range)) / range, 0), 1) : 0
        }
        func envelope(_ i: Int, _ target: Float) -> Float {
            if target >= envelopes[i] || release <= 0 { envelopes[i] = target }
            else { envelopes[i] += (target - envelopes[i]) * (1 - exp(-dt / release)) }
            return envelopes[i]
        }

        var f = AudioFeatures()
        f.active = active
        f.bass = envelope(0, autoGain(0, bandDb(20, 250)))
        f.mid = envelope(1, autoGain(1, bandDb(250, 4000)))
        f.high = envelope(2, autoGain(2, bandDb(4000, 16000)))
        f.level = envelope(3, autoGain(3, levelDb))

        // Onsets listen to the percussive part only, in their own narrower bands, so pads,
        // bass notes and chord changes don't fire them. Only feed new audio, so frames without
        // a new block don't register as a level drop and rise.
        if fresh { split.process(power: power, written: written) }
        let onsetBands: [(Float, Float)] = [(35, 120), (1500, 5000), (8000, 16000)]
        onsetDt += dt
        for (i, band) in onsetBands.enumerated() {
            let db = bandDb(band.0, band.1, of: split.percussive)
            if fresh { onsets[i].feed(db: db, active: active, sensitivity: sensitivity, dt: onsetDt) }
            onsets[i].advance(dt: dt)
        }
        if fresh { onsetDt = 0 }
        self.fresh = fresh
        f.kick = onsets[0].envelope
        f.snare = onsets[1].envelope
        f.hat = onsets[2].envelope

        let spectrumRange = range + 12
        f.harmonic = envelope(4, autoGain(4, bandDb(20, 16000, of: split.harmonic)))
        f.percussive = envelope(5, autoGain(5, bandDb(20, 16000, of: split.percussive)))
        harmonicSpectrum.update(split.harmonic, binHz: binHz, dt: dt, range: spectrumRange, release: release, active: active)
        percussiveSpectrum.update(split.percussive, binHz: binHz, dt: dt, range: spectrumRange, release: release, active: active)

        // The stems' levels are measured against the mix's peak, not their own, over a narrower
        // range. Against its own peak a stem that isn't playing has its bleed (some 40 dB down)
        // gained up into view, and one that is playing sits pinned near 1. So a stem reads 1
        // only when it is the whole mix. Zero until the separator has settled.
        peaks[6] = max(bandDb(20, 16000), peaks[6] - decayPerSec * dt, gate + range)
        if let stems {
            let stemBinHz = Float(StemSeparator.sampleRate) / Float(n)
            let stemRange = range * 0.6
            let heard = active && stems.isSettled
            for (i, r) in stems.rings.enumerated() {
                r.copyLatest(into: &samples, count: n)
                powerSpectrum(of: &samples, into: &stemPower)
                let db = bandDb(20, 16000, of: stemPower, binHz: stemBinHz)
                f.stems[i] = envelope(6 + i, heard ? min(max((db - (peaks[6] - stemRange)) / stemRange, 0), 1) : 0)
                stemSpectra[i].update(stemPower, binHz: stemBinHz, dt: dt, range: spectrumRange, release: release, active: heard)
            }
        }
        features = f

        spectrum.update(power, binHz: binHz, dt: dt, range: spectrumRange, release: release, active: active)
        os_unfair_lock_lock(&uiLock)
        uiFeatures = features
        for i in 0..<Self.spectrumBins { uiSpectrum[i] = spectrum.bins[i] }
        os_unfair_lock_unlock(&uiLock)
    }

    /// Windows `samples` (`fftSize` of them, overwritten) and writes its power spectrum, DC zeroed.
    private func powerSpectrum(of samples: inout [Float], into power: inout [Float]) {
        let n = Self.fftSize
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        var scale = 1 / Float(n * n)
        vDSP_vsmul(power, 1, &scale, &power, 1, vDSP_Length(n / 2))
        power[0] = 0
    }
}

/// A power spectrum gathered into `AudioAnalyzer.spectrumBins` log-spaced bins from 30 Hz to
/// 16 kHz, auto-gained against its own recent peak and released like the levels.
struct LogSpectrum {
    private(set) var bins = [Float](repeating: 0, count: AudioAnalyzer.spectrumBins)
    private var dbs = [Float](repeating: -120, count: AudioAnalyzer.spectrumBins)
    private var peak: Float = -40

    mutating func update(_ power: [Float], binHz: Float, dt: Float, range: Float, release: Float, active: Bool) {
        let count = bins.count
        let lo: Float = 30, hi: Float = 16000
        var frameMax: Float = -120
        for i in 0..<count {
            let f0 = lo * pow(hi / lo, Float(i) / Float(count))
            let f1 = lo * pow(hi / lo, Float(i + 1) / Float(count))
            let a = max(1, Int(f0 / binHz)), b = max(a, min(power.count - 1, Int(f1 / binHz)))
            var sum: Float = 0
            for k in a...b { sum += power[k] }
            let db = 10 * log10(sum / Float(b - a + 1) + 1e-12)
            dbs[i] = db
            frameMax = max(frameMax, db)
        }
        peak = max(frameMax, peak - 2.5 * dt, -60)
        for i in 0..<count {
            let v = active ? min(max((dbs[i] - (peak - range)) / range, 0), 1) : 0
            if v >= bins[i] || release <= 0 { bins[i] = v }
            else { bins[i] += (v - bins[i]) * (1 - exp(-dt / max(release, 0.01))) }
        }
    }
}

/// Detects hits in one band. Works on energy relative to the band's recent peak, so a hit
/// has to be loud for its band: a quiet bass note rising out of silence doesn't count as a kick.
struct OnsetDetector {
    let refractory: Float
    let decay: Float
    private(set) var envelope: Float = 0
    private var peakDb: Float = -70
    private var lastEnergy: Float = 0
    private var mean: Float = 0
    private var variance: Float = 0
    private var sinceHit: Float = 10

    init(refractory: Float, decay: Float) {
        self.refractory = refractory
        self.decay = decay
    }

    mutating func feed(db: Float, active: Bool, sensitivity: Float, dt: Float) {
        peakDb = max(db, peakDb - 1.5 * dt, -70)
        let energy = pow(10, (db - peakDb) / 10)
        let flux = max(0, energy - lastEnergy)
        lastEnergy = energy
        // Adaptive threshold: mean + k·σ of recent flux, never below a floor.
        // Higher sensitivity lowers both.
        let k = 2.5 - 1.5 * sensitivity
        let floor = 0.35 - 0.25 * sensitivity
        let threshold = max(mean + k * variance.squareRoot(), floor)
        if active, flux > threshold, sinceHit > refractory {
            envelope = 1
            sinceHit = 0
        }
        let a: Float = 0.05
        let d = flux - mean
        mean += a * d
        variance = (1 - a) * (variance + a * d * d)
    }

    mutating func advance(dt: Float) {
        sinceHit += dt
        envelope *= exp(-dt / decay)
    }
}
