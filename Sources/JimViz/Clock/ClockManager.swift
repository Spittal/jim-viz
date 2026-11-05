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

/// The Clock tool's beat engine: chooses the beat source and produces one smooth, continuous
/// beat. Each scene's `ClockRuntime` owns one.
///
/// When audio is mapped into the Clock's Audio input (Audio In · Audio Out), it tracks the
/// tempo and beat phase of the audio, falling back to the manual clock when audio is quiet,
/// ambiguous or unmapped. The output beat advances at the chosen tempo and glides toward the
/// source phase without jumping, so source switches never cause visual skips. While audio is active,
/// the manual clock follows it, so a dropout continues seamlessly.
final class ClockManager {
    let manual = InternalClock()
    let audioTempo = AudioTempo()

    /// Shifts the visuals earlier (positive) to compensate for projector and audio latency.
    /// Set each frame from the Clock's `latency` knob.
    var latencyMs: Double = 0

    // Output, written on the render thread.
    private(set) var beat: Double = 0
    private(set) var bpm: Double = 124
    private(set) var active: ClockSourceKind = .manual
    /// Whether the scene on screen maps audio into the Clock. Render thread.
    private(set) var hearsAudio = false

    /// When the user pressed First Beat, waiting for the render thread. Guarded by `lock`.
    private var firstBeatPress: CFTimeInterval?
    private let lock = NSLock()

    init() {
        bpm = manual.bpm
    }

    /// Takes over another clock's beat and tempo, so a scene's Clock continues where the
    /// previous scene's was. Render thread.
    func continueBeat(from other: ClockManager) {
        beat = other.beat
        bpm = other.bpm
        manual.sync(beat: other.manual.beat, bpm: other.manual.bpm)
    }

    /// Jumps to a beat, keeping the tempo. Render thread (the self-check calls it directly).
    func seek(beat b: Double) {
        beat = b
        manual.sync(beat: b, bpm: manual.bpm)
    }

    /// The user pressed First Beat at host time `time`, on the downbeat they heard. Following
    /// audio, the tracked beat nearest the press becomes bar 1, beat 1 of the phrase. On the
    /// manual clock, which has no grid tied to the music, the press itself is the downbeat.
    /// Applied on the next frame. Main thread.
    func firstBeat(at time: CFTimeInterval) {
        lock.lock(); firstBeatPress = time; lock.unlock()
    }

    /// Render thread, once per frame. `hearsAudio` is true while the scene on screen maps
    /// Audio In's Audio Out into the Clock; only then has the tempo estimator been fed.
    func advance(now: CFTimeInterval, dt: Double, hearsAudio: Bool) {
        let t = now + latencyMs / 1000
        // Unmapped, the estimate is dropped, so mapping again starts from fresh audio.
        if self.hearsAudio && !hearsAudio { audioTempo.reset() }
        self.hearsAudio = hearsAudio
        if hearsAudio { audioTempo.update(now: now) }

        lock.lock(); let press = firstBeatPress; firstBeatPress = nil; lock.unlock()
        if let press {
            // `beat` runs `latencyMs` ahead of the sound.
            let sincePress = (now - press + latencyMs / 1000) * bpm / 60
            if active == .audio {
                // Renumber so the beat heard at the press is 0. A whole-beat shift keeps the
                // phase, so nothing jumps.
                let shift = (beat - sincePress).rounded()
                beat -= shift
                manual.sync(beat: manual.beat - shift, bpm: manual.bpm)
            } else {
                // The press is beat 0. Renumber the output to within half a beat of it; the
                // rest of the phase glides in below. `manual.advance` adds this frame's step.
                manual.sync(beat: sincePress - dt * manual.bpm / 60, bpm: manual.bpm)
                beat -= (beat - sincePress).rounded()
            }
        }

        var target: (beat: Double, bpm: Double)?
        var source: ClockSourceKind = .manual
        if hearsAudio, let a = audioTempo.reading(at: t) {
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
}

/// Internal tempo clock at a typed tempo. Used for manual tempo and fallback.
final class InternalClock {
    /// Written on main, read on the render thread.
    var bpm: Double = 124
    private(set) var beat: Double = 0

    func advance(dt: Double) {
        beat += dt * bpm / 60
    }

    /// Follows another clock, so switching back to manual continues without a jump.
    func sync(beat: Double, bpm: Double) {
        self.beat = beat
        if bpm > 0 { self.bpm = bpm }
    }
}
