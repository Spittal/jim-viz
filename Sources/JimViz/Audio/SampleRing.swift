import Foundation
import os

/// Mono sample ring buffer. The audio queue writes; the render thread reads the latest window.
/// The writer never blocks: if the reader holds the lock, that block is dropped.
final class SampleRing {
    private let capacity: Int
    private var buffer: [Float]
    private var writeIndex = 0
    private var written = 0
    private var lock = os_unfair_lock()

    /// Updated by the writer. Read without locking for status display.
    private(set) var lastWriteTime: CFAbsoluteTime = 0
    private(set) var lastBlockPeak: Float = 0
    private(set) var sampleRate: Double = 48000

    init(capacity: Int = 16384) {
        self.capacity = capacity
        buffer = [Float](repeating: 0, count: capacity)
    }

    func setSampleRate(_ rate: Double) { sampleRate = rate }

    /// Writes `frames` samples produced by `sample(i)`.
    func write(frames: Int, sample: (Int) -> Float) {
        guard os_unfair_lock_trylock(&lock) else { return }
        var peak: Float = 0
        for i in 0..<frames {
            let s = sample(i)
            buffer[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            peak = max(peak, abs(s))
        }
        written += frames
        os_unfair_lock_unlock(&lock)
        lastBlockPeak = peak
        lastWriteTime = CFAbsoluteTimeGetCurrent()
    }

    /// Copies the most recent `count` samples, oldest first. Returns the total samples ever written,
    /// so the reader can tell whether new audio arrived.
    @discardableResult
    func copyLatest(into out: inout [Float], count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var idx = (writeIndex - count + capacity * 2) % capacity
        for i in 0..<count {
            out[i] = buffer[idx]
            idx += 1
            if idx == capacity { idx = 0 }
        }
        return written
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        for i in buffer.indices { buffer[i] = 0 }
        os_unfair_lock_unlock(&lock)
        lastBlockPeak = 0
    }
}
