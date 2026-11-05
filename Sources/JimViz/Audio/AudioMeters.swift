import Foundation
import Observation

/// Audio values for the UI, refreshed at the UI rate from the analyzer's snapshot.
@Observable
final class AudioMeters {
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var level: Float = 0
    var kick: Float = 0
    var snare: Float = 0
    var hat: Float = 0
    var spectrum = [Float](repeating: 0, count: AudioAnalyzer.spectrumBins)

    func update(from analyzer: AudioAnalyzer) {
        let (f, spec) = analyzer.snapshot()
        bass = f.bass; mid = f.mid; high = f.high; level = f.level
        kick = f.kick; snare = f.snare; hat = f.hat
        spectrum = spec
    }
}
