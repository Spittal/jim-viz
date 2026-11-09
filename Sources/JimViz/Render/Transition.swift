import Foundation
import Metal

/// Blends the outgoing scene into the incoming one whenever the active scene changes.
final class TransitionController {
    private(set) var progress: Float = 1.0
    private(set) var isTransitioning: Bool = false
    private(set) var fromScene: RenderScene?
    private(set) var toScene: RenderScene?

    private var startTime: CFTimeInterval = 0
    /// Seconds, of the blend running or last run.
    private(set) var duration: Double = TransitionSpec.default.duration
    private var lock = NSLock()

    /// Starts blending `from` into `to` over `spec.duration` seconds.
    func start(from: RenderScene, to: RenderScene, spec: TransitionSpec, now: CFTimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.fromScene = from
        self.toScene = to
        self.progress = 0.0
        self.startTime = now
        self.duration = spec.duration
        self.isTransitioning = true
    }

    /// Advances the blend on the render thread.
    func advance(now: CFTimeInterval) -> (from: RenderScene, to: RenderScene, progress: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard isTransitioning, let from = fromScene, let to = toScene else {
            return nil
        }

        let elapsed = now - startTime
        let p = duration > 0 ? Float(min(max(elapsed / duration, 0.0), 1.0)) : 1
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
