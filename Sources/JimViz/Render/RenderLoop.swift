import AppKit
import Metal
import QuartzCore

/// A window area that shows the rendered output (the projector window or the preview).
final class RenderSurface {
    let layer: CAMetalLayer
    /// Set on main from window visibility. Hidden surfaces are skipped.
    var visible = false

    init(device: MTLDevice) {
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = Renderer.drawableFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = NSColor.black.cgColor
    }
}

/// A small layer showing a video texture (a webcam's processed output), drawn each frame.
final class VideoPreview {
    let layer: RenderSurface
    /// Read on the render thread. Set once; make a new preview to show something else.
    let source: () -> MTLTexture?

    init(device: MTLDevice, source: @escaping () -> MTLTexture?) {
        layer = RenderSurface(device: device)
        self.source = source
    }
}

/// Renders on a dedicated thread, paced by a display link on the output screen,
/// so UI work on the main thread never drops frames on the projector.
final class RenderLoop: NSObject {
    let renderer: Renderer
    let clock: ClockManager
    let analyzer = AudioAnalyzer()
    let transition = TransitionController()
    /// Set by the engine. Read each frame.
    var audioRing: SampleRing?
    var audioSettings: ParamBank?

    /// Returns the scene to draw. Called on the render thread; must be cheap and thread-safe.
    var sceneProvider: () -> RenderScene? = { nil }

    private var thread: Thread!
    private var link: CADisplayLink?
    private let surfacesLock = NSLock()
    private var surfaces: [RenderSurface] = []
    private var previews: [VideoPreview] = []
    /// This frame's visible surfaces and previews, reused so presenting allocates nothing.
    private var visibleSurfaces: [RenderSurface] = []
    private var visiblePreviews: [VideoPreview] = []
    private let inFlight = DispatchSemaphore(value: 3)
    private var startTime: CFTimeInterval = 0
    private var lastTime: CFTimeInterval = 0

    // Stats read by the UI.
    private(set) var fps: Double = 0
    private(set) var gpuMs: Double = 0
    private(set) var beat: Double = 0
    private var frameCount = 0
    private var fpsWindowStart: CFTimeInterval = 0

    init(renderer: Renderer, clock: ClockManager) {
        self.renderer = renderer
        self.clock = clock
        super.init()
        let ready = DispatchSemaphore(value: 0)
        thread = Thread { [weak self] in
            ready.signal()
            // Keep the run loop alive even before a display link is attached.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            while self != nil { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "jim-viz.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func add(_ s: RenderSurface) {
        surfacesLock.lock(); surfaces.append(s); surfacesLock.unlock()
    }

    func remove(_ s: RenderSurface) {
        surfacesLock.lock(); surfaces.removeAll { $0 === s }; surfacesLock.unlock()
    }

    func add(_ p: VideoPreview) {
        surfacesLock.lock(); previews.append(p); surfacesLock.unlock()
    }

    func remove(_ p: VideoPreview) {
        surfacesLock.lock(); previews.removeAll { $0 === p }; surfacesLock.unlock()
    }

    /// Paces rendering to the given screen's refresh. Call on main whenever the output screen changes.
    func follow(screen: NSScreen) {
        let newLink = screen.displayLink(target: self, selector: #selector(step(_:)))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        perform(#selector(install(_:)), on: thread, with: newLink, waitUntilDone: false)
    }

    @objc private func install(_ newLink: CADisplayLink) {
        link?.invalidate()
        link = newLink
        newLink.add(to: .current, forMode: .default)
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        if startTime == 0 { startTime = now; lastTime = now; fpsWindowStart = now }
        let dt = min(max(now - lastTime, 1.0 / 240), 0.1)
        lastTime = now

        frameCount += 1
        if now - fpsWindowStart >= 0.5 {
            fps = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }

        let activeTransition = transition.advance(now: now)
        let primaryScene = activeTransition?.to ?? sceneProvider()
        let fromScene = activeTransition?.from
        // Audio is analysed only while a scene on screen has Audio In, and feeds the clock's
        // tempo only while one maps Audio In's Audio Out into the Clock.
        let needsAudio = primaryScene?.hasAudioInput == true || fromScene?.hasAudioInput == true
        let hearsAudio = primaryScene?.clockHearsAudio == true || fromScene?.clockHearsAudio == true

        // Audio first, so the tempo estimator sees this frame's onsets before the clock advances.
        if needsAudio, let ring = audioRing {
            analyzer.process(ring: ring, dt: Float(dt), settings: audioSettings)
            renderer.updateSpectrum(analyzer.spectrum)
            if hearsAudio && analyzer.fresh {
                clock.audioTempo.feed(strength: analyzer.onsetStrength, active: analyzer.features.active, time: now)
            }
        }
        let audio = analyzer.features

        clock.advance(now: now, dt: dt, hearsAudio: hearsAudio)
        beat = clock.beat
        guard primaryScene != nil || activeTransition != nil else { return }

        var signals = SignalFrame()
        signals.time = Float(now - startTime)
        signals.dt = Float(dt)
        signals.beat = clock.beat
        signals.bpm = Float(clock.bpm)
        signals.bass = audio.bass; signals.mid = audio.mid; signals.high = audio.high; signals.level = audio.level
        signals.kick = audio.kick; signals.snare = audio.snare; signals.hat = audio.hat

        // Shaders get only time; audio and the clock reach them through mappings.
        var frame = FrameUniforms()
        frame.time = signals.time
        frame.dt = signals.dt

        inFlight.wait()
        guard let cmd = renderer.queue.makeCommandBuffer() else { inFlight.signal(); return }

        if let (from, to, progress) = activeTransition {
            from.modulate(signals)
            to.modulate(signals)
            renderer.encodeTransition(cmd, from: from, to: to, progress: progress, frame: &frame)
        } else if let scene = primaryScene {
            scene.modulate(signals)
            renderer.encode(cmd, scene: scene, frame: &frame)
        }

        surfacesLock.lock()
        visibleSurfaces.removeAll(keepingCapacity: true)
        visiblePreviews.removeAll(keepingCapacity: true)
        for s in surfaces where s.visible { visibleSurfaces.append(s) }
        for p in previews where p.layer.visible { visiblePreviews.append(p) }
        surfacesLock.unlock()
        for p in visiblePreviews {
            guard let tex = p.source(), let drawable = p.layer.layer.nextDrawable() else { continue }
            renderer.present(cmd, tex, into: drawable.texture)
            cmd.present(drawable)
        }
        for s in visibleSurfaces {
            guard let drawable = s.layer.nextDrawable() else { continue }
            renderer.present(cmd, into: drawable.texture)
            cmd.present(drawable)
        }
        cmd.addCompletedHandler { [weak self] cb in
            self?.gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            self?.inFlight.signal()
        }
        cmd.commit()
    }
}
