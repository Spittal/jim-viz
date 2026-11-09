import Foundation
import QuartzCore

/// Audio In's beat: one smooth, continuous count that follows its source's beat tracker.
///
/// It follows the tracker's tempo, phase and, once the tracker knows it, where the bar starts.
/// When the tracker isn't sure (silence, a breakdown, a new track settling in) it carries on at
/// the last tempo; when the tracker is sure again the phase glides back, never jumping, so the
/// visuals never skip. A new downbeat renumbers the count by whole beats, which keeps the phase.
final class BeatClock {
    /// Shifts the visuals earlier (positive) to make up for projector and audio delay.
    /// Set each frame from Audio In's `latency` knob.
    var latencyMs: Double = 0

    // Output, written on the render thread.
    private(set) var beat: Double = 0
    private(set) var bpm: Double = 120
    /// Whether it follows the tracker this frame, rather than carrying on.
    private(set) var following = false
    /// Set by First Beat while following: the user's downbeat stands over the tracker's until
    /// the tracker loses the beat.
    private(set) var barPinned = false

    /// Where the beat would be at a steady tempo: what it glides toward while carrying on, so a
    /// First Beat press without a tracked beat lands smoothly.
    private var flywheel: Double = 0
    /// When the user pressed First Beat, waiting for the render thread. Guarded by `lock`.
    private var firstBeatPress: CFTimeInterval?
    private let lock = NSLock()

    /// Takes over another clock's beat and tempo, so a scene's Audio In continues where the
    /// previous scene's was. Render thread.
    func continueBeat(from other: BeatClock) {
        beat = other.beat
        bpm = other.bpm
        flywheel = other.flywheel
    }

    /// Jumps to a beat, keeping the tempo. Render thread (the self-check calls it directly).
    func seek(beat b: Double) {
        beat = b
        flywheel = b
    }

    /// The user pressed First Beat at host time `time`, on the downbeat they heard. Following
    /// the tracker, the tracked beat nearest the press becomes bar 1, beat 1 of the phrase, and
    /// stays the downbeat over the tracker's own until the tracker loses the beat. Carrying on,
    /// the press itself is the downbeat. Applied on the next frame. Any thread.
    func firstBeat(at time: CFTimeInterval) {
        lock.lock(); firstBeatPress = time; lock.unlock()
    }

    /// Render thread, once per frame.
    func advance(now: CFTimeInterval, dt: Double, source: BeatSource) {
        let t = now + latencyMs / 1000

        lock.lock(); let press = firstBeatPress; firstBeatPress = nil; lock.unlock()
        if let press {
            // `beat` runs `latencyMs` ahead of the sound.
            let sincePress = (now - press + latencyMs / 1000) * bpm / 60
            if following {
                // Renumber so the beat heard at the press is 0. A whole-beat shift keeps the
                // phase, so nothing jumps.
                let shift = (beat - sincePress).rounded()
                beat -= shift
                flywheel -= shift
                barPinned = true
            } else {
                // The press is beat 0. Renumber the output to within half a beat of it; the
                // rest of the phase glides in below, which adds this frame's step.
                flywheel = sincePress - dt * bpm / 60
                beat -= (beat - sincePress).rounded()
            }
        }

        let target = source.reading(at: t)
        if target == nil { barPinned = false }

        if let target {
            // Tempo eases quickly; phase glides with a ~250 ms time constant.
            bpm += (target.bpm - bpm) * min(1, dt * 8)
            beat += dt * bpm / 60
            beat += correction(wrapped(target.beat - beat, cycle: 1), dt: dt)
            // The tracker's downbeat: renumber by whole beats so beat 1 of the bar lands on it.
            if target.barKnown, !barPinned {
                let shift = (wrapped(target.beat - beat, cycle: 4) - wrapped(target.beat - beat, cycle: 1)).rounded()
                if shift != 0 { beat += shift }
            }
            flywheel = beat
        } else {
            flywheel += dt * bpm / 60
            let error = wrapped(flywheel - beat, cycle: 4)
            beat += dt * bpm / 60
            beat += correction(error, dt: dt)
        }
        following = target != nil
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
