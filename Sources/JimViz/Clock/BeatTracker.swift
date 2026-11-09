import AVFoundation
import Foundation

/// The beat the Clock follows: a continuous count where whole numbers are beats, and multiples
/// of 4 are downbeats once `barKnown`.
struct BeatReading {
    var beat: Double
    var bpm: Double
    var barKnown: Bool
}

/// Something the Clock can follow. `LiveBeatTracker` in the app; fixed grids in the self-check.
protocol BeatSource: AnyObject {
    func reading(at time: CFTimeInterval) -> BeatReading?
}

/// What the tracker knows, copied to the render thread: a beat grid in host time.
struct BeatEstimate {
    /// Grid beat `n` falls at `origin + n · period`.
    var origin: Double = 0
    var period: Double = 0
    /// Grid beats with `n ≡ barOffset (mod 4)` are downbeats; nil until the bar is known.
    var barOffset: Int?
    var confidence: Double = 0
    /// Host time of the last beat that landed on the grid.
    var lastBeat: Double = -.infinity

    var bpm: Double { period > 0 ? 60 / period : 0 }

    /// Usable once the grid is confident and while beats keep landing on it. Between beats
    /// (a breakdown, a quiet intro) it lets go, and the Clock carries on at the same tempo.
    func reading(at t: Double, threshold: Double = 0.35) -> BeatReading? {
        guard period > 0, confidence >= threshold, t - lastBeat < max(2, 4 * period) else { return nil }
        let n = (t - origin) / period
        return BeatReading(beat: n - Double(barOffset ?? 0), bpm: bpm, barKnown: barOffset != nil)
    }
}

/// Tracks beats and bars in audio: BeatNet's activations, a bar-pointer HMM for which frames are
/// beats and which beat is the one, and a least-squares grid over recent beats for a tempo and
/// phase finer than the 20 ms frames.
///
/// Fed audio at any rate with host times; resamples to 22.05 kHz itself. Single-threaded:
/// `LiveBeatTracker` runs it on its own thread, the self-check runs it inline.
final class BeatTracker {
    private let net = BeatNet()
    private var bar: BarPointer
    private var grid = BeatGrid()
    private(set) var minBPM: Double
    private(set) var maxBPM: Double
    private(set) var estimate = BeatEstimate()
    /// Frames analysed so far.
    var frames: Int { frame + 1 }
    /// The latest frame's activations, for diagnostics.
    private(set) var activation: (beat: Float, downbeat: Float) = (0, 0)

    // Input → 22.05 kHz, and the host time of each resampled sample.
    private var resampler: Resampler?
    private var inputStart = 0.0
    private var inputCount = 0
    private var outputCount = 0

    // A sliding window of resampled audio.
    private var buffer = [Float](repeating: 0, count: 2 * BeatNet.window)
    private var filled = 0
    private var sinceFrame = 0

    // Recent frames, for refining beat times between frames.
    private static let history = 8
    private var acts = [Float](repeating: 0, count: history)
    private var times = [Double](repeating: 0, count: history)
    private var frame = -1
    private var pending: [(frame: Int, beatInBar: Int, interval: Int)] = []
    private var lastBeatFrame = Int.min / 2
    private var wasOnBeat = false

    init(minBPM: Double = 90, maxBPM: Double = 180) {
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        bar = BarPointer(minBPM: minBPM, maxBPM: maxBPM, fps: BeatNet.fps)
        pending.reserveCapacity(4)
    }

    /// The tempo range to search. A change starts tracking afresh.
    func setRange(minBPM lo: Double, maxBPM hi: Double) {
        guard lo != minBPM || hi != maxBPM else { return }
        minBPM = lo; maxBPM = hi
        bar = BarPointer(minBPM: lo, maxBPM: hi, fps: BeatNet.fps)
        grid = BeatGrid()
        estimate = BeatEstimate()
    }

    func reset() {
        net.reset()
        bar.reset()
        grid = BeatGrid()
        estimate = BeatEstimate()
        resampler = nil
        filled = 0; sinceFrame = 0; frame = -1
        pending.removeAll(keepingCapacity: true)
        lastBeatFrame = Int.min / 2
        wasOnBeat = false
    }

    /// Adds audio at `rate`; `time` is the host time of its first sample.
    func push(_ samples: UnsafeBufferPointer<Float>, rate: Double, time: Double) {
        if resampler?.rate != rate {
            resampler = Resampler(from: rate)
            inputCount = 0; outputCount = 0
            inputStart = time
        }
        // Follow the host clock, ignoring sub-millisecond jitter.
        if abs(inputStart + Double(inputCount) / rate - time) > 0.002 {
            inputStart = time - Double(inputCount) / rate
        }
        inputCount += samples.count
        resampler!.process(samples) { out in
            for s in out { append(s) }
        }
    }

    private func append(_ s: Float) {
        if filled == buffer.count {
            let keep = BeatNet.window - 1
            buffer.withUnsafeMutableBufferPointer { b in
                _ = memmove(b.baseAddress!, b.baseAddress! + filled - keep, keep * 4)
            }
            filled = keep
        }
        buffer[filled] = s
        filled += 1
        outputCount += 1
        sinceFrame += 1
        if sinceFrame >= BeatNet.hop, filled >= BeatNet.window {
            sinceFrame = 0
            let end = inputStart + Double(outputCount - 1) / BeatNet.sampleRate - resampler!.latency
            buffer.withUnsafeBufferPointer { b in
                analyse(b.baseAddress! + filled - BeatNet.window, centre: end - BeatNet.centreDelay)
            }
        }
    }

    /// One 20 ms frame whose centre is at host time `centre`.
    private func analyse(_ window: UnsafePointer<Float>, centre: Double) {
        let a = net.step(window)
        activation = a
        frame += 1
        acts[frame % Self.history] = a.beat + a.downbeat
        times[frame % Self.history] = centre
        let s = bar.step(beat: a.beat, downbeat: a.downbeat)

        // A beat when the most likely state enters a beat's first sixteenth.
        let onBeat = Double(s.framesIntoBeat) / Double(s.interval) < 1 / BarPointer.observationLambda
        let beatFrame = frame - s.framesIntoBeat
        if onBeat, !wasOnBeat || beatFrame != lastBeatFrame, beatFrame - lastBeatFrame > s.interval / 2 {
            pending.append((beatFrame, s.beatInBar, s.interval))
            lastBeatFrame = beatFrame
        }
        wasOnBeat = onBeat

        // Two frames later, place it on the activation's peak between frames.
        while let p = pending.first, p.frame + 2 <= frame {
            pending.removeFirst()
            place(p.frame, beatInBar: p.beatInBar, interval: p.interval)
        }
    }

    private func place(_ k: Int, beatInBar: Int, interval: Int) {
        let oldest = max(0, frame - Self.history + 1)
        func act(_ i: Int) -> Float { acts[i % Self.history] }
        var m = k
        for i in max(oldest, k - 2)...min(frame, k + 2) where act(i) > act(m) || m < oldest { m = i }
        guard m >= oldest else { return }
        var offset = 0.0
        if m - 1 >= oldest, m + 1 <= frame {
            let l = Double(act(m - 1)), c = Double(act(m)), r = Double(act(m + 1))
            let den = l - 2 * c + r
            if den < 0 { offset = min(max(0.5 * (l - r) / den, -0.5), 0.5) }
        }
        let time = times[m % Self.history] + offset / BeatNet.fps
        grid.add(time: time, beatInBar: beatInBar, strength: act(m), period: Double(interval) / BeatNet.fps)
        estimate = grid.estimate
    }
}

/// A steady beat grid fitted to tracked beats: each beat gets a number, and a weighted
/// least-squares line through the recent ones gives tempo and phase finer than the HMM's whole
/// frames.
///
/// It's built for music that mostly keeps one tempo: what it has learnt outweighs a few odd
/// beats. Confidence builds up beat by beat while beats land on the grid, drops a little for
/// each clear beat that doesn't, and holds through silence and breakdowns. A beat is clear when
/// it's at least 70% as strong as this music's typical beat; weaker ones (a breakdown, a pad)
/// count for nothing either way. The grid starts again only on sustained evidence (a mix into a new track): clear
/// beats where the HMM's tempo disagrees with the grid's, or that miss the grid, piling up to
/// more the more confident it is, from 3 beats' worth to about 12. Starting again keeps the old
/// grid running, and half its confidence, until the new one has enough beats to fit.
///
/// The bar comes from votes: each beat votes for which grid beats are downbeats, by the HMM's
/// beat-in-bar, fading over about a dozen bars, and a new answer has to win by twice the old
/// one's votes to replace it: slow and sticky, so the bar holds steady.
struct BeatGrid {
    private struct Beat { var time: Double; var number: Int; var beatInBar: Int; var strength: Float }

    /// Beats weaker than this (a breakdown, silence) aren't counted.
    static let minStrength: Float = 0.1
    private static let keep = 32

    private(set) var estimate = BeatEstimate()
    private var beats: [Beat] = []
    private var offGrid: [Beat] = []
    private var votes = [Double](repeating: 0, count: BarPointer.beatsPerBar)
    /// Evidence against the grid: clear beats whose HMM tempo disagrees, summed by strength.
    private var disagreement = 0.0
    /// How strong this music's beats usually are: a running average of clear beats.
    private var typical: Float = 0

    /// Evidence needed to start again: more the more confident the grid is.
    private var restartEvidence: Double { 3 + 9 * estimate.confidence }

    mutating func add(time: Double, beatInBar: Int, strength: Float, period hmmPeriod: Double) {
        guard strength >= Self.minStrength else { return }
        var beat = Beat(time: time, number: 0, beatInBar: beatInBar, strength: strength)
        let clear = strength >= 0.7 * typical
        if clear { typical += (strength - typical) * 0.1 }
        guard let last = beats.last else { beats = [beat]; return }

        if beats.count < 3 {
            // Too few to fit: number by the HMM's tempo.
            beat.number = last.number + max(1, Int(((time - last.time) / hmmPeriod).rounded()))
            accept(beat, clear: clear)
            return
        }
        // Does the HMM still hear the grid's tempo? Only clear beats get a say.
        if clear {
            if abs(estimate.period / hmmPeriod - 1) > 0.06 {
                disagreement += Double(strength)
                estimate.confidence *= 0.98
                if disagreement >= restartEvidence { restart(with: [beat], period: hmmPeriod); return }
            } else {
                disagreement = 0
            }
        }
        let p = (time - estimate.origin) / estimate.period
        let n = Int(p.rounded())
        if abs(p - Double(n)) < 0.25 {
            guard n > last.number else { return }  // the same beat again
            beat.number = n
            accept(beat, clear: clear)
        } else if clear {
            offGrid.append(beat)
            offGrid.removeAll { time - $0.time > 16 * hmmPeriod }
            estimate.confidence *= 0.96
            let evidence = offGrid.reduce(0) { $0 + Double($1.strength) }
            if evidence >= restartEvidence { restart(with: Array(offGrid.suffix(4)), period: hmmPeriod) }
        }
    }

    /// A new grid from `seed`, numbered by the HMM's tempo. The old grid's tempo and phase carry
    /// on until the new one has enough beats to fit, with half the confidence.
    private mutating func restart(with seed: [Beat], period: Double) {
        var seed = seed
        seed[0].number = 0
        for i in seed.indices.dropFirst() {
            seed[i].number = seed[i - 1].number + max(1, Int(((seed[i].time - seed[i - 1].time) / period).rounded()))
        }
        beats = []
        offGrid.removeAll()
        disagreement = 0
        for i in votes.indices { votes[i] = 0 }
        estimate.confidence *= 0.5
        estimate.barOffset = nil
        for b in seed { accept(b, clear: true) }
    }

    private mutating func accept(_ beat: Beat, clear: Bool) {
        beats.append(beat)
        if beats.count > Self.keep { beats.removeFirst() }
        for i in votes.indices { votes[i] *= 0.98 }
        let bars = BarPointer.beatsPerBar
        votes[((beat.number - beat.beatInBar) % bars + bars) % bars] += Double(beat.strength)
        fit(updateConfidence: clear)
        decideBar()
        estimate.lastBeat = beat.time
    }

    /// Weighted least squares of time against beat number, recent and strong beats counting most:
    /// about the last 20 beats, so the tempo holds steady and follows a pitch fader in a few bars.
    private mutating func fit(updateConfidence: Bool) {
        guard beats.count >= 3 else { return }
        let lastN = Double(beats.last!.number)
        var sw = 0.0, sn = 0.0, st = 0.0
        var ws = [Double](repeating: 0, count: beats.count)
        for (i, b) in beats.enumerated() {
            let w = pow(0.95, lastN - Double(b.number)) * Double(max(b.strength, 0.05))
            ws[i] = w; sw += w; sn += w * Double(b.number); st += w * b.time
        }
        let mn = sn / sw, mt = st / sw
        var snn = 0.0, snt = 0.0
        for (i, b) in beats.enumerated() {
            let dn = Double(b.number) - mn
            snn += ws[i] * dn * dn; snt += ws[i] * dn * (b.time - mt)
        }
        guard snn > 0 else { return }
        let period = snt / snn
        guard period > 0.2, period < 2 else { return }
        estimate.period = period
        estimate.origin = mt - period * mn
        var se = 0.0, sumStrength = 0.0
        for (i, b) in beats.enumerated() {
            let e = b.time - (estimate.origin + period * Double(b.number))
            se += ws[i] * e * e
            sumStrength += Double(b.strength)
        }
        let rms = (se / sw).squareRoot()
        // Steady beats (jitter well under a tenth of a beat), enough of them, clearly heard.
        let steadiness = max(0, min(1, 1 - rms / (0.08 * period)))
        let enough = min(1, Double(beats.count - 2) / 4)
        let clear = min(1, sumStrength / Double(beats.count) / 0.3)
        let target = steadiness * enough * clear
        // Builds up beat by beat (about 8 beats to settle), so one odd beat only nudges it.
        if updateConfidence { estimate.confidence += (target - estimate.confidence) * 0.2 }
    }

    private mutating func decideBar() {
        let order = votes.indices.sorted { votes[$0] > votes[$1] }
        let best = order[0]
        if let current = estimate.barOffset {
            if best != current, votes[best] > 2 * votes[current] + 0.5 { estimate.barOffset = best }
        } else if votes[best] >= 2, votes[best] > 2 * votes[order[1]] {
            estimate.barOffset = best
        }
    }
}

/// Streams audio to 22.05 kHz with AVAudioConverter.
final class Resampler {
    let rate: Double
    /// How far each output sample lags the input sample it stands for, in seconds. Measured once
    /// per rate with an impulse.
    let latency: Double
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    private static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: BeatNet.sampleRate, channels: 1, interleaved: false)!
    private static let capacity = 16384

    init(from rate: Double) {
        self.rate = rate
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inFormat, to: Self.outFormat)!
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(Self.capacity))!
        let outCap = Int((Double(Self.capacity) * BeatNet.sampleRate / rate).rounded(.up)) + 256
        output = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: AVAudioFrameCount(outCap))!
        latency = Self.measureLatency(rate: rate)
    }

    func process(_ samples: UnsafeBufferPointer<Float>, _ emit: (UnsafeBufferPointer<Float>) -> Void) {
        var start = 0
        while start < samples.count {
            let n = min(Self.capacity, samples.count - start)
            memcpy(input.floatChannelData![0], samples.baseAddress! + start, n * 4)
            input.frameLength = AVAudioFrameCount(n)
            start += n
            var fed = false
            while true {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if fed { state.pointee = .noDataNow; return nil }
                    fed = true
                    state.pointee = .haveData
                    return self.input
                }
                if output.frameLength > 0 {
                    emit(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                }
                if status != .haveData { break }
            }
        }
    }

    private static var latencies: [Double: Double] = [:]
    private static let latencyLock = NSLock()

    /// Feeds an impulse through a fresh converter and finds where it comes out.
    private static func measureLatency(rate: Double) -> Double {
        latencyLock.lock(); defer { latencyLock.unlock() }
        if let l = latencies[rate] { return l }
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: inFormat, to: outFormat)!
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let n = Int(rate / 5), at = n / 4
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n))!
        inBuf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { inBuf.floatChannelData![0][i] = i == at ? 1 : 0 }
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n))!
        var fed = false, error: NSError?
        _ = conv.convert(to: outBuf, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return inBuf
        }
        let out = UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
        let peak = out.indices.max { abs(out[$0]) < abs(out[$1]) } ?? 0
        let l = Double(peak) / BeatNet.sampleRate - Double(at) / rate
        latencies[rate] = l
        return l
    }
}
