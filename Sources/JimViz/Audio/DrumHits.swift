import Foundation

/// Finds kick, snare and hat hits in the separated drum stem, one hop (128 samples at 44.1 kHz,
/// 2.9 ms) at a time, on the stems thread.
///
/// The stem goes through three filters: below 150 Hz for the kick, 1.5–5 kHz for the snare or
/// clap, above 8 kHz for the hats. Each band's level is averaged over a few hops, and a hit is a
/// level that has risen `rise` dB within the last few hops and stands within `depth` dB of the
/// band's recent peak. The depth is what tells the drums apart: a kick's click and a hat's
/// spill reach the snare band too, but well below where the snares stand.
///
/// The snare and hat bands also check each other, since a snare's noise reaches the top and a
/// hat's spills down: a hat needs the snare band less than 6 dB above the hat band, and a snare
/// the hat band less than 6 dB above the snare band. A hat under a snare is therefore not
/// reported.
///
/// Last, a hit must stand within 40 dB of the loudest band's peak, so that in a band nothing has
/// played in yet (no snares so far, say) another drum's faint spill isn't taken for its drum.
///
/// What it can't fix is the separator: a punchy bass note it lets into the drum stem reads as a
/// kick, and hats it loses in a dense mix are missed.
struct DrumHits {
    /// Kick, snare, hat: the order of `feed`'s result.
    static let count = 3

    private var bands = [
        // Butterworth sections at 44.1 kHz (scipy.signal.butter, as b0, b1, b2, a1, a2).
        // Low-pass 150 Hz, 4th order. Six hops of averaging cover a 40 Hz kick's cycle.
        Band(sections: [[1.2680874150452636e-08, 2.5361748300905273e-08, 1.2680874150452636e-08, -1.9608304562685264, 0.9612783322580798],
                        [1, 2, 1, -1.9833239558223639, 0.983776969583181]],
             smooth: 6, lag: 4, depth: 12, refractory: 0.11),
        // Band-pass 1.5–5 kHz, 2nd order.
        Band(sections: [[0.04550162653087958, 0.09100325306175916, 0.04550162653087958, -1.2932080253253697, 0.6044340152049862],
                        [1, -2, 1, -1.7651008576451939, 0.8182382160517202]],
             smooth: 2, lag: 3, depth: 9, refractory: 0.09),
        // High-pass 8 kHz, 4th order.
        Band(sections: [[0.20271577969980312, -0.40543155939960623, 0.20271577969980312, -0.4542475801634095, 0.08731500560118874],
                        [1, -2, 1, -0.6199802267798911, 0.48402288353699097]],
             smooth: 2, lag: 3, depth: 18, refractory: 0.05),
    ]

    /// Takes the drum stem's next hop and returns 1 for each drum that hit in it. `sensitivity`
    /// is Audio In's knob, 0...1: higher accepts smaller rises and quieter hits.
    mutating func feed(_ hop: UnsafePointer<Float>, sensitivity: Float) -> SIMD3<Int32> {
        let rise = 6 * (1.5 - sensitivity)
        let depth = 0.5 + sensitivity
        for i in bands.indices { bands[i].measure(hop) }
        let floor = bands.map(\.peak).max()! - 40
        let tilt = bands[2].db - bands[1].db  // hat band over snare band
        let allowed = [true, tilt < 6, tilt > -6]
        var hits = SIMD3<Int32>()
        for i in bands.indices where bands[i].step(rise: rise, depthScale: depth, allowed: allowed[i] && bands[i].db > floor) { hits[i] = 1 }
        return hits
    }

    /// One second-order filter section and its state.
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
    }

    private struct Band {
        var sections: [Biquad]
        /// The hop on its way through the filter.
        var scratch = [Double](repeating: 0, count: StemSeparator.hop)
        /// Hops the level is averaged over, hops back a rise is measured against, dB below the
        /// peak a hit may stand, and hops between hits.
        let smooth: Int, lag: Int, depth: Float, refractory: Int
        var energies: [Float]
        var energyIndex = 0
        /// The level over the last `smooth` hops, in dB, and the `lag` levels before it.
        var db: Float = -120
        var history: [Float] = []
        var peak: Float = -70
        var sinceHit = 1000

        init(sections: [[Double]], smooth: Int, lag: Int, depth: Float, refractory: Double) {
            self.sections = sections.map { Biquad(b0: $0[0], b1: $0[1], b2: $0[2], a1: $0[3], a2: $0[4]) }
            self.smooth = smooth
            self.lag = lag
            self.depth = depth
            self.refractory = Int(refractory * StemSeparator.sampleRate / Double(StemSeparator.hop))
            energies = [Float](repeating: 0, count: smooth)
        }

        /// Filters the hop and updates the level and its peak.
        mutating func measure(_ hop: UnsafePointer<Float>) {
            let n = StemSeparator.hop
            var sum = 0.0
            scratch.withUnsafeMutableBufferPointer { x in
                for i in 0..<n { x[i] = Double(hop[i]) }
                for s in sections.indices {
                    var f = sections[s]
                    for i in 0..<n {
                        let y = f.b0 * x[i] + f.z1
                        f.z1 = f.b1 * x[i] - f.a1 * y + f.z2
                        f.z2 = f.b2 * x[i] - f.a2 * y
                        x[i] = y
                    }
                    sections[s] = f
                }
                for i in 0..<n { sum += x[i] * x[i] }
            }
            energies[energyIndex] = Float(sum / Double(n))
            energyIndex = (energyIndex + 1) % smooth
            if history.isEmpty { history = [Float](repeating: db, count: lag) }
            history.removeFirst()
            history.append(db)
            db = 10 * log10(energies.reduce(0, +) / Float(smooth) + 1e-12)
            // The peak falls 1.5 dB a second, so quieter passages still register.
            peak = max(db, peak - 1.5 * Float(Double(StemSeparator.hop) / StemSeparator.sampleRate), -70)
        }

        /// Whether the level just measured is a hit.
        mutating func step(rise: Float, depthScale: Float, allowed: Bool) -> Bool {
            sinceHit += 1
            guard allowed, db - history.min()! > rise, db > peak - depth * depthScale, sinceHit > refractory else { return false }
            sinceHit = 0
            return true
        }
    }
}
