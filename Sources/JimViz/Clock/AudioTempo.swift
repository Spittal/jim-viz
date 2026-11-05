import Accelerate
import Foundation

/// Estimates tempo and beat phase from the analyzer's onset strength.
///
/// Onset strength is binned into a 100 Hz envelope over the last 8 seconds. Each candidate
/// tempo is scored by summing the envelope's autocorrelation at 1–4 beat lags (a comb), with a
/// weak preference for tempos near `preferredBPM` to settle half/double-time ambiguity. Phase
/// comes from the offset where the envelope lines up best with a beat grid, weighted toward
/// recent audio.
final class AudioTempo {
    struct Reading {
        var beat: Double
        var bpm: Double
    }

    static let rate: Double = 100
    static let windowSeconds: Double = 8
    /// Spreads one frame's onset over five slots.
    private static let kernel: [Float] = [0.1, 0.25, 0.3, 0.25, 0.1]

    /// Settable from main; read on the render thread.
    /// One octave by default, so a tempo and its half/double can't both be candidates.
    var minBPM: Double = 90
    var maxBPM: Double = 180
    var preferredBPM: Double = 125
    /// Detection runs slightly behind the sound; shift phase earlier by this much.
    var detectionLatency: Double = 0.025

    private let n = Int(rate * windowSeconds)
    private var env: [Float]
    private var lastSlot: Int?
    private var filledSlots = 0
    private var lastUpdate: CFTimeInterval = 0
    private var lastActive: CFTimeInterval = 0

    // Output model.
    private(set) var bpm: Double = 0
    private(set) var confidence: Double = 0
    private var anchorBeat: Double = 0
    private var anchorTime: CFTimeInterval = 0
    private var candidate: Double = 0
    private var candidateVotes = 0

    private let lock = NSLock()

    init() { env = [Float](repeating: 0, count: n) }

    /// Adds one frame's onset strength. Spreads it over neighbouring slots so the frame rate
    /// (60 or 120 Hz) doesn't imprint a pattern on the 100 Hz envelope.
    func feed(strength: Float, active: Bool, time: CFTimeInterval) {
        if active { lastActive = time }
        let slot = Int((time * Self.rate).rounded(.down))
        if lastSlot == nil { lastSlot = slot }
        while lastSlot! < slot + 2 {
            lastSlot! += 1
            env[lastSlot! % n] = 0
            filledSlots += 1
        }
        for (k, w) in Self.kernel.enumerated() {
            let s = slot + k - 2
            env[((s % n) + n) % n] += strength * w
        }
    }

    /// Re-estimates four times a second.
    func update(now: CFTimeInterval) {
        guard now - lastUpdate >= 0.25, let end = lastSlot else { return }
        lastUpdate = now
        let enough = filledSlots > Int(Self.rate * 4)
        let active = now - lastActive < 1.5
        guard enough, active else {
            lock.lock(); confidence = max(0, confidence - 0.1); lock.unlock()
            return
        }

        // Unroll the ring, oldest first, mean-removed. The last 2 slots are still being filled.
        let count = n - 2
        var x = [Float](repeating: 0, count: count)
        for i in 0..<count { x[i] = env[(((end - 2 - count + 1 + i) % n) + n) % n] }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(count))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(count))

        // Autocorrelation for lags up to four beats at the slowest tempo.
        let maxLag = min(count - 1, Int(60 * Self.rate / minBPM * 4) + 2)
        var r = [Float](repeating: 0, count: maxLag + 1)
        x.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(count - lag))
                r[lag] = dot / Float(count - lag)
            }
        }
        guard r[0] > 1e-9 else { return }

        // Catmull-Rom interpolation: smooth between lags, so peaks between samples are found
        // accurately (linear interpolation biases tempo toward whole-sample lags).
        func interp(_ lag: Double) -> Float {
            let i = Int(lag), t = Float(lag - Double(i))
            guard i >= 1, i + 2 <= maxLag else { return 0 }
            let p0 = r[i - 1], p1 = r[i], p2 = r[i + 1], p3 = r[i + 2]
            let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
            let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
            let c = -0.5 * p0 + 0.5 * p2
            return ((a * t + b) * t + c) * t + p1
        }

        // Score candidates on a 0.1 BPM grid.
        var bestBPM = 0.0, bestScore: Float = -.infinity
        var total: Float = 0, samples = 0
        let weights: [Float] = [1, 0.6, 0.4, 0.3]
        var b = minBPM
        while b <= maxBPM {
            let lag = 60 * Self.rate / b
            var score: Float = 0
            for (k, w) in weights.enumerated() where lag * Double(k + 1) < Double(maxLag) {
                score += w * interp(lag * Double(k + 1))
            }
            // If half this period also correlates strongly, the real tempo is probably double.
            score -= 0.5 * max(0, interp(lag / 2))
            let octaves = log2(b / preferredBPM)
            score *= Float(exp(-0.5 * octaves * octaves / 0.5))
            if score > bestScore { bestScore = score; bestBPM = b }
            total += score; samples += 1
            b += 0.1
        }
        let meanScore = total / Float(max(samples, 1))
        let conf = Double(max(0, min(1, (bestScore - meanScore) / (abs(bestScore) + 1e-9))))

        let phaseTime = beatPhase(x: x, endSlot: end - 2, bpm: bestBPM)

        lock.lock(); defer { lock.unlock() }
        confidence += (conf - confidence) * 0.3
        adopt(bpm: bestBPM, lastBeatTime: phaseTime - detectionLatency)
    }

    /// Time of the most recent beat for the given tempo.
    private func beatPhase(x: [Float], endSlot: Int, bpm: Double) -> CFTimeInterval {
        let period = 60 * Self.rate / bpm
        let count = x.count
        var bestPhi = 0.0, best: Float = -.infinity
        var phi = 0.0
        while phi < period {
            var s: Float = 0, w: Float = 1
            var k = 0.0
            while true {
                let idx = Double(count - 1) - phi - k * period
                guard idx >= 0 else { break }
                s += x[Int(idx)] * w
                w *= 0.92
                k += 1
            }
            if s > best { best = s; bestPhi = phi }
            phi += 0.5
        }
        return (Double(endSlot) - bestPhi) / Self.rate
    }

    /// Smooths tempo changes and keeps the beat count continuous.
    private func adopt(bpm newBPM: Double, lastBeatTime: CFTimeInterval) {
        if bpm == 0 {
            bpm = newBPM
            anchorBeat = 0
            anchorTime = lastBeatTime
            return
        }
        if abs(newBPM - bpm) / bpm < 0.04 {
            bpm += (newBPM - bpm) * 0.3
            candidateVotes = 0
        } else {
            // A different tempo must win three estimates in a row before we switch.
            if abs(newBPM - candidate) / max(candidate, 1) < 0.02 { candidateVotes += 1 } else { candidate = newBPM; candidateVotes = 1 }
            if candidateVotes >= 3 { bpm = newBPM; candidateVotes = 0 }
        }
        // Re-anchor on the detected beat, keeping the nearest whole beat number.
        let predicted = anchorBeat + (lastBeatTime - anchorTime) * bpm / 60
        anchorBeat = predicted.rounded()
        anchorTime = lastBeatTime
    }

    /// Usable when the estimate is confident and audio is active.
    func reading(at time: CFTimeInterval, threshold: Double = 0.35) -> Reading? {
        lock.lock(); defer { lock.unlock() }
        guard bpm > 0, confidence >= threshold, time - lastActive < 2 else { return nil }
        return Reading(beat: anchorBeat + (time - anchorTime) * bpm / 60, bpm: bpm)
    }

    func status() -> (bpm: Double, confidence: Double) {
        lock.lock(); defer { lock.unlock() }
        return (bpm, confidence)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in env.indices { env[i] = 0 }
        lastSlot = nil; filledSlots = 0; bpm = 0; confidence = 0; candidateVotes = 0
    }
}
