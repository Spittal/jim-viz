import Foundation

/// Joint beat and bar tracking: the forward algorithm on a bar-pointer HMM (Krebs, Böck and
/// Widmer 2015, as in madmom's downbeat tracker, run causally like Böck's online beat tracker).
/// Deterministic, unlike BeatNet's particle filter, so the same audio always gives the same beats.
///
/// A state is a tempo (whole frames per beat) and a position within a 4/4 bar at that tempo.
/// Each frame the position advances by one; at each beat boundary the tempo may change, less
/// likely the further it moves. The first sixteenth of each beat is "on the beat" and weighed by
/// BeatNet's beat activation (its downbeat activation for beat 1); the rest by the chance of
/// neither. A few thousand states at the default range: microseconds a frame.
struct BarPointer {
    static let beatsPerBar = 4
    /// How strongly tempo changes are penalised (madmom's transition_lambda).
    static let tempoLambda = 100.0
    /// The first 1/16 of each beat is on the beat (madmom's observation_lambda).
    static let observationLambda = 16.0

    /// The most likely state after a frame.
    struct State {
        /// Frames per beat.
        var interval: Int
        /// Frames since the bar began.
        var position: Int
        var beatInBar: Int { position / interval }
        var framesIntoBeat: Int { position % interval }
    }

    let intervals: [Int]
    private let offsets: [Int]
    private let count: Int
    /// Per state: 0 between beats, 1 on a beat, 2 on the downbeat.
    private let kind: [UInt8]
    /// Tempo change at a beat boundary, `[from * tempi + to]`.
    private let transition: [Double]
    private var alpha: [Double]
    private var ends: [Double]

    init(minBPM: Double, maxBPM: Double, fps: Double) {
        let lo = max(2, Int((60 * fps / maxBPM).rounded(.up)))
        let hi = max(lo, Int((60 * fps / minBPM).rounded(.down)))
        intervals = Array(lo...hi)
        var offsets: [Int] = [], kind: [UInt8] = []
        for tau in intervals {
            offsets.append(kind.count)
            for p in 0..<(Self.beatsPerBar * tau) {
                let onBeat = Double(p % tau) / Double(tau) < 1 / Self.observationLambda
                kind.append(onBeat ? (p < tau ? 2 : 1) : 0)
            }
        }
        self.offsets = offsets
        self.kind = kind
        count = kind.count
        let n = intervals.count
        var t = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            var sum = 0.0
            for j in 0..<n {
                let v = exp(-Self.tempoLambda * abs(Double(intervals[j]) / Double(intervals[i]) - 1))
                t[i * n + j] = v
                sum += v
            }
            for j in 0..<n { t[i * n + j] /= sum }
        }
        transition = t
        alpha = [Double](repeating: 1 / Double(count), count: count)
        ends = [Double](repeating: 0, count: n * Self.beatsPerBar)
    }

    mutating func reset() {
        for i in alpha.indices { alpha[i] = 1 / Double(count) }
    }

    /// Advances one frame with BeatNet's activations and returns the most likely state.
    mutating func step(beat: Float, downbeat: Float) -> State {
        let n = intervals.count, bars = Self.beatsPerBar
        // The last frame of each beat, at each tempo, before shifting.
        for j in 0..<n {
            let tau = intervals[j], o = offsets[j]
            for b in 0..<bars { ends[j * bars + b] = alpha[o + (b + 1) * tau - 1] }
        }
        // Advance every pointer one frame.
        for j in 0..<n {
            let tau = intervals[j], o = offsets[j]
            var p = o + bars * tau - 1
            while p > o { alpha[p] = alpha[p - 1]; p -= 1 }
            // Each beat starts from the end of the previous beat, at any tempo.
            for b in 0..<bars {
                var s = 0.0
                for i in 0..<n { s += ends[i * bars + b] * transition[i * n + j] }
                alpha[o + ((b + 1) % bars) * tau] = s
            }
        }
        // Weigh by the observation, normalise, and find the most likely state.
        let b = Double(max(beat, 1e-6)), d = Double(max(downbeat, 1e-6))
        let none = max(1 - b - d, 1e-6) / (Self.observationLambda - 1)
        var sum = 0.0
        for s in 0..<count {
            let k = kind[s]
            alpha[s] *= k == 0 ? none : (k == 1 ? b : d)
            sum += alpha[s]
        }
        var best = 0, bestP = -1.0
        let inv = 1 / sum
        for s in 0..<count {
            alpha[s] *= inv
            if alpha[s] > bestP { bestP = alpha[s]; best = s }
        }
        var j = n - 1
        while offsets[j] > best { j -= 1 }
        return State(interval: intervals[j], position: best - offsets[j])
    }
}
