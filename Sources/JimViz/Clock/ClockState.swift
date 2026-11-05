import Foundation
import Observation
import QuartzCore

/// Clock status and settings for the UI. Settings are persisted and pushed to the
/// `ClockManager`; status is refreshed from it at the UI rate.
@Observable
final class ClockState {
    @ObservationIgnored private let clock: ClockManager
    @ObservationIgnored private let defaults = UserDefaults.standard

    var mode: ClockMode { didSet { clock.mode = mode; defaults.set(mode.rawValue, forKey: "clock.mode") } }
    var latencyMs: Double { didSet { clock.latencyMs = latencyMs; defaults.set(latencyMs, forKey: "clock.latencyMs") } }
    var minBPM: Double { didSet { clock.audioTempo.minBPM = minBPM; defaults.set(minBPM, forKey: "clock.minBPM") } }
    var maxBPM: Double { didSet { clock.audioTempo.maxBPM = maxBPM; defaults.set(maxBPM, forKey: "clock.maxBPM") } }

    private(set) var active: ClockSourceKind = .manual
    private(set) var bpm: Double = 124
    private(set) var audioBPM: Double = 0
    private(set) var audioConfidence: Double = 0
    private(set) var audioUsable = false
    /// Whether the scene on screen maps audio into the Clock.
    private(set) var hearsAudio = false

    init(clock: ClockManager) {
        self.clock = clock
        mode = ClockMode(rawValue: defaults.string(forKey: "clock.mode") ?? "") ?? .audio
        latencyMs = defaults.object(forKey: "clock.latencyMs") as? Double ?? 0
        minBPM = defaults.object(forKey: "clock.minBPM") as? Double ?? 90
        maxBPM = defaults.object(forKey: "clock.maxBPM") as? Double ?? 180
        clock.mode = mode
        clock.latencyMs = latencyMs
        clock.audioTempo.minBPM = minBPM
        clock.audioTempo.maxBPM = maxBPM
    }

    /// Called at UI rate. Only assigns when values change, to limit SwiftUI updates.
    func refresh() {
        if active != clock.active { active = clock.active }
        if hearsAudio != clock.hearsAudio { hearsAudio = clock.hearsAudio }
        if abs(bpm - clock.bpm) > 0.05 { bpm = clock.bpm }
        let a = clock.audioTempo.status()
        if abs(a.bpm - audioBPM) > 0.05 { audioBPM = a.bpm }
        if abs(a.confidence - audioConfidence) > 0.01 { audioConfidence = a.confidence }
        let usable = clock.audioTempo.reading(at: CACurrentMediaTime()) != nil
        if usable != audioUsable { audioUsable = usable }
    }

    /// Manual tempo entry. Typing a tempo means you want the manual clock.
    func setManualBPM(_ v: Double) {
        clock.manual.bpm = min(max(v, 40), 250)
        mode = .manual
    }

    func tap() {
        if clock.tap() { mode = .manual }
    }

    func resync() { clock.manual.resync() }
}
