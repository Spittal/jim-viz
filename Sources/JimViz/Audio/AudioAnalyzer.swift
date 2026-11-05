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
    /// True when there is signal above the gate.
    var active = false
}

/// Audio In's knobs: analysis settings, per scene and mappable (`audio.<name>`).
enum AudioParams {
    static let defs: [ParamDef] = [
        ParamDef(name: "range", defaultValue: 30, min: 6, max: 60, isInt: false),
        ParamDef(name: "release", defaultValue: 0.12, min: 0, max: 1, isInt: false),
        ParamDef(name: "sensitivity", defaultValue: 0.5, min: 0, max: 1, isInt: false),
        ParamDef(name: "gate", defaultValue: -50, min: -90, max: -20, isInt: false),
    ]
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
    private var lastWritten = 0

    private(set) var features = AudioFeatures()
    /// Weighted onset flux of this frame, for tempo estimation. 0 when no new audio arrived.
    private(set) var onsetStrength: Float = 0
    /// True when this frame analysed new audio.
    private(set) var fresh = false
    /// Log-spaced spectrum, 0...1, for shaders.
    private(set) var spectrum = [Float](repeating: 0, count: spectrumBins)
    private(set) var spectrumVersion = 0
    private var uiLock = os_unfair_lock()
    private var uiFeatures = AudioFeatures()
    private var uiSpectrum = [Float](repeating: 0, count: spectrumBins)

    /// Thread-safe copy for the UI.
    func snapshot() -> (AudioFeatures, [Float]) {
        os_unfair_lock_lock(&uiLock); defer { os_unfair_lock_unlock(&uiLock) }
        return (uiFeatures, uiSpectrum)
    }

    // Auto-gain and envelope state per band.
    private var peaks: [Float] = Array(repeating: -40, count: 7)
    private var envelopes: [Float] = Array(repeating: 0, count: 4)
    private var spectrumPeak: Float = -40
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
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Picks up another analyzer's auto-gain, envelopes and onset state, so a scene's Audio In
    /// continues where the previous scene's left off instead of re-learning levels. Render thread.
    func continueState(from other: AudioAnalyzer) {
        peaks = other.peaks
        envelopes = other.envelopes
        spectrumPeak = other.spectrumPeak
        spectrum = other.spectrum
        onsets = other.onsets
        onsetDt = other.onsetDt
        features = other.features
        lastWritten = other.lastWritten
    }

    /// Analyzes the latest window. `settings` holds live values of `AudioParams`.
    func process(ring: SampleRing, dt: Float, settings: ParamBank?) {
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

        // Windowed real FFT → power spectrum.
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

        let binHz = rate / Float(n)
        func bandDb(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / binHz)), b = min(n / 2 - 1, max(a, Int(hi / binHz)))
            var sum: Float = 0
            power.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + a, 1, &sum, vDSP_Length(b - a + 1)) }
            return 10 * log10(sum + 1e-12)
        }

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

        // Onsets use their own narrower bands. Only feed new audio, so frames without a new
        // block don't register as a level drop and rise.
        let onsetBands: [(Float, Float)] = [(35, 120), (1500, 5000), (8000, 16000)]
        onsetDt += dt
        for (i, band) in onsetBands.enumerated() {
            let db = bandDb(band.0, band.1)
            if fresh { onsets[i].feed(db: db, active: active, sensitivity: sensitivity, dt: onsetDt) }
            onsets[i].advance(dt: dt)
        }
        if fresh { onsetDt = 0 }
        self.fresh = fresh
        onsetStrength = fresh ? onsets[0].lastFlux + 0.5 * onsets[1].lastFlux + 0.25 * onsets[2].lastFlux : 0
        f.kick = onsets[0].envelope
        f.snare = onsets[1].envelope
        f.hat = onsets[2].envelope
        features = f

        updateSpectrum(binHz: binHz, dt: dt, range: range + 12, release: release, active: active)
    }

    private func updateSpectrum(binHz: Float, dt: Float, range: Float, release: Float, active: Bool) {
        let bins = Self.spectrumBins
        let lo: Float = 30, hi: Float = 16000
        var frameMax: Float = -120
        var dbs = [Float](repeating: -120, count: bins)
        for i in 0..<bins {
            let f0 = lo * pow(hi / lo, Float(i) / Float(bins))
            let f1 = lo * pow(hi / lo, Float(i + 1) / Float(bins))
            let a = max(1, Int(f0 / binHz)), b = max(a, min(power.count - 1, Int(f1 / binHz)))
            var sum: Float = 0
            for k in a...b { sum += power[k] }
            let db = 10 * log10(sum / Float(b - a + 1) + 1e-12)
            dbs[i] = db
            frameMax = max(frameMax, db)
        }
        spectrumPeak = max(frameMax, spectrumPeak - 2.5 * dt, -60)
        for i in 0..<bins {
            let v = active ? min(max((dbs[i] - (spectrumPeak - range)) / range, 0), 1) : 0
            if v >= spectrum[i] || release <= 0 { spectrum[i] = v }
            else { spectrum[i] += (v - spectrum[i]) * (1 - exp(-dt / max(release, 0.01))) }
        }
        spectrumVersion &+= 1
        os_unfair_lock_lock(&uiLock)
        uiFeatures = features
        for i in 0..<bins { uiSpectrum[i] = spectrum[i] }
        os_unfair_lock_unlock(&uiLock)
    }
}

/// Detects hits in one band. Works on energy relative to the band's recent peak, so a hit
/// has to be loud for its band: a quiet bass note rising out of silence doesn't count as a kick.
struct OnsetDetector {
    let refractory: Float
    let decay: Float
    private(set) var envelope: Float = 0
    private(set) var lastFlux: Float = 0
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
        lastFlux = active ? flux : 0
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
