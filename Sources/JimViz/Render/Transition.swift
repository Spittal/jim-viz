import Foundation
import Metal

/// Manages a smooth 300ms crossfade whenever the active scene changes.
final class TransitionController {
    static let durationSeconds: Double = 0.30

    private(set) var progress: Float = 1.0
    private(set) var isTransitioning: Bool = false
    private(set) var fromScene: RenderScene?
    private(set) var toScene: RenderScene?

    private var startTime: CFTimeInterval = 0
    private var lock = NSLock()

    /// Starts a 300ms crossfade from `from` to `to`.
    func start(from: RenderScene, to: RenderScene, now: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.fromScene = from
        self.toScene = to
        self.progress = 0.0
        self.startTime = now
        self.isTransitioning = true
    }

    /// Advances crossfade progress on the render thread.
    func advance(now: CFTimeInterval) -> (from: RenderScene, to: RenderScene, progress: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard isTransitioning, let from = fromScene, let to = toScene else {
            return nil
        }

        let elapsed = now - startTime
        let p = Float(min(max(elapsed / Self.durationSeconds, 0.0), 1.0))
        self.progress = p

        if p >= 1.0 {
            self.isTransitioning = false
            self.fromScene = nil
        }

        return (from, to, progress)
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        isTransitioning = false
        fromScene = nil
        toScene = nil
        progress = 1.0
    }
}
