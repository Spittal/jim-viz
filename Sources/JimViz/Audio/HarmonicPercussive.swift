import Foundation

/// Splits a power spectrum into harmonic (sustained, tonal) and percussive (short, broadband)
/// parts by median filtering (Fitzgerald 2010). Tonal energy is steady over time, so the median
/// of a bin's recent history keeps it; a hit is flat across frequency, so the median of a
/// frame's neighbouring bins keeps it. Each bin's power is shared between the two by a soft
/// (Wiener) mask, so harmonic + percussive = the input.
///
/// Causal: the history holds only past frames, so a hit shows up as percussive on the frame it
/// arrives. A new sustained note counts as harmonic once it fills half the history (~115 ms).
struct HarmonicPercussive {
    /// Frames of history the harmonic median looks back over.
    static let historyFrames = 11
    /// A history frame is taken every this many new samples, so the look-back is a fixed length
    /// of time (~230 ms at 48 kHz) whatever the display's frame rate.
    static let hopSamples = 1024
    /// Bins either side in the percussive median (~190 Hz at 2048 points, 48 kHz).
    static let halfWidth = 8

    let bins: Int
    private(set) var harmonic: [Float]
    private(set) var percussive: [Float]
    /// `historyFrames` rows of `bins`, rotating.
    private var history: [Float]
    private var row = 0
    private var lastHop = -hopSamples
    /// Median over time of each bin's history, refreshed when a frame is added.
    private var harmonicMedian: [Float]
    private var scratch = [Float](repeating: 0, count: max(historyFrames, 2 * halfWidth + 1))

    init(bins: Int) {
        self.bins = bins
        harmonic = [Float](repeating: 0, count: bins)
        percussive = [Float](repeating: 0, count: bins)
        history = [Float](repeating: 0, count: Self.historyFrames * bins)
        harmonicMedian = [Float](repeating: 0, count: bins)
    }

    /// Splits this frame's `power`. `written` is the sample count the frame ends at.
    mutating func process(power: [Float], written: Int) {
        if written - lastHop >= Self.hopSamples || written < lastHop {
            lastHop = written
            let base = row * bins
            for k in 0..<bins { history[base + k] = power[k] }
            row = (row + 1) % Self.historyFrames
            for k in 0..<bins {
                for r in 0..<Self.historyFrames { scratch[r] = history[r * bins + k] }
                harmonicMedian[k] = median(Self.historyFrames)
            }
        }
        let w = Self.halfWidth
        for k in 0..<bins {
            let lo = max(0, k - w), hi = min(bins - 1, k + w)
            for j in lo...hi { scratch[j - lo] = power[j] }
            let p = median(hi - lo + 1)
            let h = harmonicMedian[k]
            let total = h + p
            let mask = total > 0 ? h / total : 0.5
            harmonic[k] = power[k] * mask
            percussive[k] = power[k] - harmonic[k]
        }
    }

    /// Median of the first `n` values of `scratch`, by insertion sort (n ≤ 17).
    private mutating func median(_ n: Int) -> Float {
        for i in 1..<n {
            let v = scratch[i]
            var j = i - 1
            while j >= 0, scratch[j] > v { scratch[j + 1] = scratch[j]; j -= 1 }
            scratch[j + 1] = v
        }
        return scratch[n / 2]
    }
}
