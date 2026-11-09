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
    /// Host time of the first sample of the latest block, and its index. Guarded by `lock`.
    private var blockTime: CFTimeInterval = 0
    private var blockStart = 0

    init(capacity: Int = 16384) {
        self.capacity = capacity
        buffer = [Float](repeating: 0, count: capacity)
    }

    func setSampleRate(_ rate: Double) { sampleRate = rate }

    /// Writes `frames` samples produced by `sample(i)`. `hostTime` is when the first was
    /// captured (`CACurrentMediaTime` seconds).
    func write(frames: Int, hostTime: CFTimeInterval, sample: (Int) -> Float) {
        guard os_unfair_lock_trylock(&lock) else { return }
        blockTime = hostTime
        blockStart = written
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

    /// Copies up to `max` samples starting at absolute index `from` (skipping ahead if they've
    /// been overwritten). Returns where the copy started, how many, and the host time of sample
    /// `start`, from the latest block's timestamp.
    func read(from: Int, into out: UnsafeMutablePointer<Float>, max: Int) -> (start: Int, count: Int, time: CFTimeInterval) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let start = Swift.max(from, written - capacity)
        let count = Swift.min(Swift.max(0, written - start), max)
        var idx = (writeIndex - (written - start) + capacity * 2) % capacity
        for i in 0..<count {
            out[i] = buffer[idx]
            idx += 1
            if idx == capacity { idx = 0 }
        }
        return (start, count, blockTime - Double(blockStart - start) / sampleRate)
    }

    /// Total samples written so far.
    var writtenCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return written
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        for i in buffer.indices { buffer[i] = 0 }
        os_unfair_lock_unlock(&lock)
        lastBlockPeak = 0
    }
}
