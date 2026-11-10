import Accelerate
import Foundation
import QuartzCore

/// Splits one capture's audio into drums, bass, vocals and other with a `StemSeparator`, on its
/// own thread, as the audio arrives. One per `AudioCapture`, so scenes listening to the same
/// source share it.
///
/// It runs only while a scene's stem outputs are mapped: each frame that scene's Audio In calls
/// `demand`; a second without one stops the thread and clears the stems. The model loads on
/// first use, on this thread. The stems go into `rings` at 44.1 kHz, which the render thread
/// analyses like the input; they lag the audio by the separator's 5.8 ms plus the resampler's.
///
/// The networks misbehave around silence, which is handled here:
/// - Fed half a second of silence, the vocal network then passes the whole mix for about 4 s.
///   So while the input is below the gate the networks are paused, keeping their memory of the
///   music, and the stems are silent.
/// - With no memory at all (just started, or reset), the stems leak for the first 1.5 s of
///   audio. `isSettled` is false until then, and the analyzer holds the stems at zero.
final class LiveStems {
    /// Drums, bass, vocals, other (`StemSeparator.Stem` order).
    let rings: [SampleRing]
    private let ring: SampleRing
    private let queue = DispatchQueue(label: "jim-viz.stems", qos: .userInteractive)

    // Guarded by `lock`.
    private let lock = NSLock()
    private var lastDemand: CFTimeInterval = 0
    private var running = false
    private var gate: Float = 0
    private var settled = false

    // Stems queue only.
    private var timer: DispatchSourceTimer?
    private var separator: StemSeparator?
    private var resampler: Resampler?
    private var readPos: Int?
    private var scratch = [Float](repeating: 0, count: 16384)
    private var hop = [Float](repeating: 0, count: StemSeparator.hop)
    private var filled = 0
    /// Hops in a row below the gate, and hops separated since the networks' memory was cleared.
    private var quietHops = 0
    private var heardHops = 0
    /// A gap shorter than this (50 ms) is separated as usual; short gaps do no harm.
    private static let quietHopsToPause = Int(0.05 * StemSeparator.sampleRate) / StemSeparator.hop
    private static let hopsToSettle = Int(1.5 * StemSeparator.sampleRate) / StemSeparator.hop
    private var stems = [Float](repeating: 0, count: 4 * StemSeparator.hop)

    init(ring: SampleRing) {
        self.ring = ring
        rings = StemSeparator.Stem.allCases.map { _ in
            let r = SampleRing(capacity: 8192)
            r.setSampleRate(StemSeparator.sampleRate)
            return r
        }
    }

    /// Render thread, each frame a scene's stem outputs are mapped. `gate` is Audio In's gate
    /// in dB: input below it counts as silence.
    func demand(gate: Float) {
        lock.lock()
        lastDemand = CACurrentMediaTime()
        self.gate = pow(10, gate / 20)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.startTimer() } }
    }

    /// Whether the separator is running: a scene has demanded it within the last second.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Whether the networks have heard enough audio for the stems to be trusted.
    var isSettled: Bool { lock.lock(); defer { lock.unlock() }; return settled }

    /// Separates whatever audio has arrived, now, on the calling thread's behalf. For offline
    /// renders, which write audio faster than real time.
    func catchUp() { queue.sync { separate() } }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // The capture delivers ~10 ms blocks; polling at 2 ms keeps the wait for one short.
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        lock.lock()
        let idle = CACurrentMediaTime() - lastDemand > 1
        if idle { running = false }
        lock.unlock()
        guard idle else { return separate() }
        timer?.cancel()
        timer = nil
        resampler = nil
        readPos = nil
        forget()
        for r in rings { r.reset() }
    }

    /// Clears the networks' memory, after which they need to settle again.
    private func forget() {
        separator?.reset()
        filled = 0
        quietHops = 0
        heardHops = 0
        lock.lock(); settled = false; lock.unlock()
    }

    /// Stems queue: resamples the new audio to 44.1 kHz and runs the separator on each full hop.
    private func separate() {
        if separator == nil { separator = StemSeparator(weights: .shared) }
        let rate = ring.sampleRate
        if resampler?.rate != rate {
            resampler = Resampler(from: rate, to: StemSeparator.sampleRate)
            forget()
        }
        var pos = readPos ?? ring.writtenCount
        while true {
            let got = scratch.withUnsafeMutableBufferPointer { ring.read(from: pos, into: $0.baseAddress!, max: $0.count) }
            guard got.count > 0 else { break }
            if got.start != pos { forget() }  // fell behind: the ring moved on
            scratch.withUnsafeBufferPointer { s in
                resampler!.process(UnsafeBufferPointer(rebasing: s[0..<got.count])) { out in
                    for x in out { push(x, time: got.time) }
                }
            }
            pos = got.start + got.count
        }
        readPos = pos
    }

    private func push(_ x: Float, time: CFTimeInterval) {
        hop[filled] = x
        filled += 1
        guard filled == StemSeparator.hop else { return }
        filled = 0
        let n = StemSeparator.hop
        var peak: Float = 0
        vDSP_maxmgv(hop, 1, &peak, vDSP_Length(n))
        lock.lock(); let gate = gate; lock.unlock()
        quietHops = peak < gate ? quietHops + 1 : 0
        if quietHops > Self.quietHopsToPause {
            for i in stems.indices { stems[i] = 0 }
        } else {
            hop.withUnsafeBufferPointer { h in
                stems.withUnsafeMutableBufferPointer { s in separator!.step(h.baseAddress!, s.baseAddress!) }
            }
            heardHops += 1
            if heardHops == Self.hopsToSettle { lock.lock(); settled = true; lock.unlock() }
        }
        for (i, r) in rings.enumerated() {
            r.write(frames: n, hostTime: time) { stems[i * n + $0] }
        }
    }
}
