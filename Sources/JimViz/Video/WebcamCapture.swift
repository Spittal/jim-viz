import AVFoundation
import CoreVideo
import Metal
import Observation

struct WebcamDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Every camera the system can see, and one feed per camera in use.
/// Feeds start when a scene that uses them is on screen and stop when none does.
@Observable
final class WebcamManager {
    private(set) var devices: [WebcamDeviceInfo] = []
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var feeds: [String: WebcamFeed] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// No capture in the self-check; feeds there get test frames instead.
    @ObservationIgnored var captureEnabled = true

    init(device: MTLDevice) {
        metal = device
    }

    /// Call once the app has launched.
    func start() {
        refresh()
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                self?.restartActive()
            })
        }
    }

    func refresh() {
        let found = Self.discover().map { WebcamDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        if found != devices { devices = found }
    }

    /// The feed for a camera by name; nil means the first camera found.
    func feed(named name: String?) -> WebcamFeed {
        let key = name ?? ""
        if let f = feeds[key] { return f }
        let f = WebcamFeed(name: name, metal: metal)
        feeds[key] = f
        return f
    }

    /// Every feed made so far, running or not.
    var allFeeds: [WebcamFeed] { Array(feeds.values) }

    /// Runs exactly these feeds.
    func activate(_ active: [WebcamFeed]) {
        let ids = Set(active.map(ObjectIdentifier.init))
        for f in feeds.values where !ids.contains(ObjectIdentifier(f)) { f.stop() }
        guard captureEnabled, !active.isEmpty else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
            for f in active { f.start(Self.resolve(f.name)) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = granted ? .authorized : .denied
                    if granted { for f in active { f.start(Self.resolve(f.name)) } }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
            for f in active { f.setStatus(.denied) }
        }
    }

    private func restartActive() {
        guard authorization == .authorized else { return }
        for f in feeds.values where f.wanted { f.start(Self.resolve(f.name)) }
    }

    private static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    private static func resolve(_ name: String?) -> AVCaptureDevice? {
        let all = discover()
        guard let name else { return AVCaptureDevice.default(for: .video) ?? all.first }
        return all.first { $0.localizedName == name }
    }
}

/// One camera's frames as Metal textures, plus cheap brightness and motion readings.
/// Frames arrive on a capture queue; the render thread takes the latest.
@Observable
final class WebcamFeed: VideoSourceFeed {
    enum Status: Equatable { case off, starting, running, notFound, denied, failed(String) }

    /// Camera name it asked for; nil is the default camera.
    let name: String?
    private(set) var status: Status = .off
    /// Name of the camera actually in use.
    private(set) var activeName: String?

    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private let queue = DispatchQueue(label: "jim-viz.webcam", qos: .userInteractive)
    @ObservationIgnored private var cache: CVMetalTextureCache?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var frame: VideoFrame?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private(set) var wanted = false
    /// Brightness and motion, 0...1, written on the capture queue, read by outputs on the render thread.
    @ObservationIgnored private var luma = LumaGrid()
    var brightness: Float { luma.brightness }
    var motion: Float { luma.motion }

    /// Depth from the camera image. Runs only while `depthWanted`, that is while a scene on
    /// screen has this camera's Depth output mapped.
    @ObservationIgnored let depth: DepthEstimator
    @ObservationIgnored var depthWanted = false {
        didSet { if !depthWanted { depth.reset() } }
    }

    init(name: String?, metal: MTLDevice) {
        self.name = name
        self.metal = metal
        depth = DepthEstimator(metal: metal)
        CVMetalTextureCacheCreate(nil, nil, metal, nil, &cache)
    }

    /// Latest frame, or nil before the first one.
    func latest() -> VideoFrame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func setStatus(_ s: Status) {
        if Thread.isMainThread { if status != s { status = s } }
        else { DispatchQueue.main.async { if self.status != s { self.status = s } } }
    }

    func start(_ device: AVCaptureDevice?) {
        wanted = true
        guard let device else { stopSession(); setStatus(.notFound); return }
        if session?.isRunning == true, activeName == device.localizedName { return }
        stopSession()
        setStatus(.starting)
        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 } else { s.sessionPreset = .high }
        guard let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) else {
            s.commitConfiguration(); setStatus(.failed("could not open \(device.localizedName)")); return
        }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                             kCVPixelBufferMetalCompatibilityKey as String: true]
        out.alwaysDiscardsLateVideoFrames = true
        let d = Delegate { [weak self] buffer in self?.receive(buffer) }
        out.setSampleBufferDelegate(d, queue: queue)
        guard s.canAddOutput(out) else { s.commitConfiguration(); setStatus(.failed("no video output")); return }
        s.addOutput(out)
        s.commitConfiguration()
        delegate = d
        session = s
        activeName = device.localizedName
        queue.async { s.startRunning() }
    }

    func stop() {
        wanted = false
        stopSession()
        setStatus(.off)
    }

    private func stopSession() {
        if let s = session { queue.async { s.stopRunning() } }
        session = nil
        delegate = nil
    }

    /// Self-check: a frame from a texture instead of a camera.
    func inject(_ texture: MTLTexture) {
        lock.lock(); frame = VideoFrame(texture: texture, owner: nil); lock.unlock()
        status = .running
    }

    private func receive(_ buffer: CVPixelBuffer) {
        guard let cache else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        luma.analyze(buffer)
        if depthWanted { depth.submit(buffer) }
        lock.lock(); frame = VideoFrame(texture: tex, owner: cvTex); lock.unlock()
        if status != .running { setStatus(.running) }
    }

    private final class Delegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let onFrame: (CVPixelBuffer) -> Void
        init(_ onFrame: @escaping (CVPixelBuffer) -> Void) { self.onFrame = onFrame }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame(pb) }
        }
    }
}

/// A Webcam in the scene's Inputs section, on one camera's feed.
final class WebcamRuntime: VideoSourceRuntime {
    /// Camera name asked for; nil is the default camera.
    let device: String?
    let feed: WebcamFeed

    init(id: String, device: String?, bank: ParamBank, feed: WebcamFeed, gpu: VideoSourceGPU) {
        self.device = device; self.feed = feed
        super.init(key: "webcam.\(id)", id: id, label: device ?? "Webcam", bank: bank, feed: feed, gpu: gpu)
    }
}
