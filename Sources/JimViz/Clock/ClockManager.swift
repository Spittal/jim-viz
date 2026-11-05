import Foundation
import QuartzCore

enum ClockSourceKind: String, CaseIterable, Identifiable {
    case audio, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audio: return "Audio"
        case .manual: return "Manual"
        }
    }
}

/// Audio follows the beat of the audio mapped into the Clock's Audio input (Audio In · Onsets),
/// falling back to the manual tempo while there's no steady beat or nothing is mapped.
/// Manual ignores the audio.
enum ClockMode: String, CaseIterable, Identifiable {
    case audio, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audio: return "Audio"
        case .manual: return "Manual"
        }
    }
}

/// Chooses the beat clock and produces one smooth, continuous beat for the visuals.
///
/// Audio mode uses the audio tempo estimate when a steady beat is heard in the mapped audio,
/// and falls back to the manual clock when audio is quiet, ambiguous or unmapped. The output beat advances at the chosen
/// tempo and glides toward the source phase without jumping, so source switches never cause
/// visual skips. While audio is active, the manual clock follows it, so a dropout continues
/// at the current tempo.
final class ClockManager {
    let manual = InternalClock()
    let audioTempo = AudioTempo()

    // Settings, written on main.
    var mode: ClockMode = .audio
    /// Shifts the visuals earlier (positive) to compensate for projector and audio latency.
    var latencyMs: Double = 0

    // Output, written on the render thread.
    private(set) var beat: Double = 0
    private(set) var bpm: Double = 124
    private(set) var active: ClockSourceKind = .manual
    /// Whether the scene on screen maps audio into the Clock. Render thread.
    private(set) var hearsAudio = false

    init() {
        bpm = manual.bpm
    }

    /// Render thread, once per frame. `hearsAudio` is true while the scene on screen maps
    /// Audio In's Onsets into the Clock; only then has the tempo estimator been fed.
    func advance(now: CFTimeInterval, dt: Double, hearsAudio: Bool) {
        let t = now + latencyMs / 1000
        // Unmapped, the estimate is dropped, so mapping again starts from fresh audio.
        if self.hearsAudio && !hearsAudio { audioTempo.reset() }
        self.hearsAudio = hearsAudio
        if hearsAudio { audioTempo.update(now: now) }

        var target: (beat: Double, bpm: Double)?
        var source: ClockSourceKind = .manual
        if mode == .audio, hearsAudio, let a = audioTempo.reading(at: t) {
            target = (a.beat, a.bpm); source = .audio
        }

        if let target {
            // Tempo eases quickly; phase glides with a ~250 ms time constant.
            bpm += (target.bpm - bpm) * min(1, dt * 8)
            beat += dt * bpm / 60
            beat += correction(wrapped(target.beat - beat, cycle: 1), dt: dt)
            // Keep the manual clock in step, so a dropout continues seamlessly.
            manual.sync(beat: beat, bpm: bpm)
        } else {
            manual.advance(dt: dt)
            bpm = manual.bpm
            let error = wrapped(manual.beat - beat, cycle: 4)
            beat += dt * bpm / 60
            beat += correction(error, dt: dt)
        }
        active = source
    }

    /// Phase correction for one frame: tiny errors snap, others glide with a ~250 ms time
    /// constant, but never faster than ±50% of the tempo, like nudging a platter.
    private func correction(_ error: Double, dt: Double) -> Double {
        if abs(error) < 0.01 { return error }
        let limit = 0.5 * dt * bpm / 60
        return min(max(error * min(1, dt * 4), -limit), limit)
    }

    /// Wraps a beat difference into [-cycle/2, cycle/2), so the output keeps counting forward
    /// and only the phase within the cycle is corrected.
    private func wrapped(_ d: Double, cycle: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: cycle)
        if x >= cycle / 2 { x -= cycle }
        if x < -cycle / 2 { x += cycle }
        return x
    }

    /// Tap tempo. Switches to manual if another source is driving the clock.
    func tap() -> Bool {
        manual.tap()
        if active != .manual {
            mode = .manual
            return true
        }
        return false
    }
}
