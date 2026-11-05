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
/// tempo and downbeat of the audio, falling back to the manual clock when audio is quiet,
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

    private var pendingFirstBeat = false

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

    /// Snap to the first beat of the phrase (bar 1, beat 1) on the next frame.
    func firstBeat() {
        pendingFirstBeat = true
    }

    /// Render thread, once per frame. `hearsAudio` is true while the scene on screen maps
    /// Audio In's Audio Out into the Clock; only then has the tempo estimator been fed.
    func advance(now: CFTimeInterval, dt: Double, hearsAudio: Bool) {
        let t = now + latencyMs / 1000
        // Unmapped, the estimate is dropped, so mapping again starts from fresh audio.
        if self.hearsAudio && !hearsAudio { audioTempo.reset() }
        self.hearsAudio = hearsAudio
        if hearsAudio { audioTempo.update(now: now) }

        if pendingFirstBeat {
            pendingFirstBeat = false
            audioTempo.setFirstBeat()
            let frac = beat - floor(beat)
            beat = frac
            manual.sync(beat: beat, bpm: bpm)
        }

        var target: (beat: Double, bpm: Double)?
        var source: ClockSourceKind = .manual
        if hearsAudio, let a = audioTempo.reading(at: t) {
            target = (a.beat, a.bpm); source = .audio
        }

        if let target {
            // If audio tempo detected a phrase drop, align the phrase boundary.
            if audioTempo.consumePhraseDrop() {
                let frac = beat - floor(beat)
                beat = (round(beat / 32) * 32) + frac
            } else if audioTempo.downbeatConfidence > 0.35 {
                // Downbeat alignment check: align bar position (0..<4) without changing fractional phase
                let targetBar = ((Int(floor(target.beat)) % 4) + 4) % 4
                let clockBar = ((Int(floor(beat)) % 4) + 4) % 4
                let diff = ((targetBar - clockBar) % 4 + 4) % 4
                if diff != 0 {
                    let adj = diff > 2 ? diff - 4 : diff
                    beat += Double(adj)
                }
            }

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

    /// Tap tempo.
    @discardableResult
    func tap() -> Bool {
        manual.tap()
        return true
    }
}

/// Internal tempo clock with tap tempo. Used for manual tempo and fallback.
final class InternalClock {
    /// Written on main, read on the render thread.
    var bpm: Double = 124
    private(set) var beat: Double = 0
    private var taps: [CFTimeInterval] = []
    private var pendingResync = false

    func advance(dt: Double) {
        if pendingResync {
            beat = 0
            pendingResync = false
        }
        beat += dt * bpm / 60
    }

    /// Snap to the first beat of the phrase (bar 1, beat 1) on the following frame.
    func firstBeat() { pendingResync = true }

    /// Snap to the first beat / downbeat.
    func resync() { firstBeat() }

    /// Follows another clock, so switching back to manual continues without a jump.
    func sync(beat: Double, bpm: Double) {
        self.beat = beat
        if bpm > 0 { self.bpm = bpm }
    }

    func tap(at t: CFTimeInterval = CACurrentMediaTime()) {
        if let last = taps.last, t - last > 2 { taps.removeAll() }
        taps.append(t)
        if taps.count > 8 { taps.removeFirst() }
        guard taps.count >= 3 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0 - $1 }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        bpm = min(max(60 / avg, 40), 250)
        resync()
    }
}
