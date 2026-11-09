import Foundation
import QuartzCore

/// Runs a `BeatTracker` on one capture's audio, on its own thread, every 10 ms, through each
/// new 20 ms hop as it arrives, whatever the display's frame rate. One per `AudioCapture`, so
/// scenes listening to the same source share what it has learnt and a scene switch doesn't
/// start over.
///
/// It runs only while a Clock follows it: each frame the Clock calls `demand`; a second
/// without one stops the thread and forgets the beat, so following again starts afresh.
/// The render thread reads `reading(at:)`, which only copies the latest estimate under a lock.
final class LiveBeatTracker: BeatSource {
    private let ring: SampleRing
    private let queue = DispatchQueue(label: "jim-viz.beats", qos: .userInteractive)
    /// Analysis queue only.
    private var timer: DispatchSourceTimer?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var lastDemand: CFTimeInterval = 0
    private var range = (min: 90.0, max: 180.0)
    private var running = false
    private var published = BeatEstimate()

    // Analysis queue only. The tracker (and BeatNet's weights) load on first use.
    private lazy var tracker = BeatTracker()
    private var readPos: Int?
    private var scratch = [Float](repeating: 0, count: 16384)

    init(ring: SampleRing) { self.ring = ring }

    /// Render thread, each frame a Clock follows this source, with its tempo range.
    func demand(minBPM: Double, maxBPM: Double) {
        lock.lock()
        lastDemand = CACurrentMediaTime()
        range = (minBPM, maxBPM)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.startTimer() } }
    }

    func reading(at time: CFTimeInterval) -> BeatReading? {
        lock.lock(); defer { lock.unlock() }
        return published.reading(at: time)
    }

    /// Tempo and confidence, for the UI.
    func status() -> (bpm: Double, confidence: Double, barKnown: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (published.bpm, published.confidence, published.barOffset != nil)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock()
        let idle = now - lastDemand > 1
        let r = range
        if idle {
            running = false
            published = BeatEstimate()
        }
        lock.unlock()
        if idle {
            timer?.cancel()
            timer = nil
            tracker.reset()
            readPos = nil
            return
        }

        tracker.setRange(minBPM: r.min, maxBPM: r.max)
        let rate = ring.sampleRate
        var pos = readPos ?? max(0, ring.writtenCount - Int(rate / 10))
        while true {
            let got = scratch.withUnsafeMutableBufferPointer { ring.read(from: pos, into: $0.baseAddress!, max: $0.count) }
            guard got.count > 0 else { break }
            if got.start != pos { tracker.reset() }  // fell behind: the ring moved on
            scratch.withUnsafeBufferPointer { s in
                tracker.push(UnsafeBufferPointer(rebasing: s[0..<got.count]), rate: rate, time: got.time)
            }
            pos = got.start + got.count
        }
        readPos = pos
        let e = tracker.estimate
        lock.lock(); published = e; lock.unlock()
    }
}
