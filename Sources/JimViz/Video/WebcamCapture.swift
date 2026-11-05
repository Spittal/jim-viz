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
    @ObservationIgnored private let queue = DispatchQueue(label: "jimviz.webcam", qos: .userInteractive)
    @ObservationIgnored private var cache: CVMetalTextureCache?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var frame: VideoFrame?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private(set) var wanted = false
    @ObservationIgnored private var previous: [Float] = []

    /// 0...1, written on the capture queue, read by outputs on the render thread.
    @ObservationIgnored private(set) var brightness: Float = 0
    @ObservationIgnored private(set) var motion: Float = 0

    /// Depth from the camera image. Runs only while `depthWanted`, that is while a scene on
    /// screen has this camera's Depth output mapped.
    @ObservationIgnored let depth: DepthEstimator
    @ObservationIgnored var depthWanted = false {
        didSet { if !depthWanted { depth.reset() } }
    }

    typealias Frame = VideoFrame

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
        analyze(buffer, w, h)
        if depthWanted { depth.submit(buffer) }
        lock.lock(); frame = VideoFrame(texture: tex, owner: cvTex); lock.unlock()
        if status != .running { setStatus(.running) }
    }

    /// Average brightness and frame-to-frame change over a coarse 32×18 grid.
    private func analyze(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let gx = 32, gy = 18
        var grid = [Float](repeating: 0, count: gx * gy)
        var sum: Float = 0
        for j in 0..<gy {
            let y = (j * 2 + 1) * h / (gy * 2)
            for i in 0..<gx {
                let x = (i * 2 + 1) * w / (gx * 2)
                let p = base + y * row + x * 4
                let l = (Float(p[2]) * 0.2126 + Float(p[1]) * 0.7152 + Float(p[0]) * 0.0722) / 255
                grid[j * gx + i] = l
                sum += l
            }
        }
        brightness = sum / Float(grid.count)
        if previous.count == grid.count {
            var diff: Float = 0
            for k in grid.indices { diff += abs(grid[k] - previous[k]) }
            let m = min(diff / Float(grid.count) * 8, 1)
            motion += (m - motion) * 0.5
        }
        previous = grid
    }

    private final class Delegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let onFrame: (CVPixelBuffer) -> Void
        init(_ onFrame: @escaping (CVPixelBuffer) -> Void) { self.onFrame = onFrame }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame(pb) }
        }
    }
}

/// A Webcam in the scene's Inputs section. Its knobs (from `Shaders/inputs/webcam.metal`)
/// process the feed into `processed`, which is its video output; it also has value outputs,
/// motion and brightness. Its second video output, Depth, is estimated from the image: grey,
/// white = near.
final class WebcamRuntime: VideoSourceRuntime {
    let id: String
    /// Camera name asked for; nil is the default camera.
    let device: String?
    let bank: ParamBank
    let feed: WebcamFeed
    var sourceFeed: any VideoSourceFeed { feed }
    let pipeline: MTLRenderPipelineState?
    /// The processed video, written by the renderer each frame.
    let processed: MTLTexture
    /// Value outputs: motion and brightness.
    private(set) var outputs: [OutputSignal] = []
    /// Its video output, `webcam.<id>.video`.
    let video: StreamOutput
    /// Its depth output, `webcam.<id>.depth`, drawn by `depthPipeline` from the estimator's
    /// latest depth into `depth`. `depthHistory` holds last frame's, for smoothing.
    let depthVideo: StreamOutput
    let depth: MTLTexture
    let depthPipeline: MTLRenderPipelineState?
    let depthHistory: MTLTexture
    /// Set when the scene maps the Depth output somewhere; only then does the model run.
    var depthMapped = false

    var key: String { "webcam.\(id)" }
    var videoKey: String { "\(key).video" }

    init(id: String, device: String?, bank: ParamBank, feed: WebcamFeed, pipeline: MTLRenderPipelineState?, processed: MTLTexture,
         depthPipeline: MTLRenderPipelineState?, depth: MTLTexture, depthHistory: MTLTexture) {
        self.id = id; self.device = device; self.bank = bank; self.feed = feed
        self.pipeline = pipeline; self.processed = processed
        self.depthPipeline = depthPipeline; self.depthHistory = depthHistory; self.depth = depth
        let label = device ?? "Webcam"
        video = StreamOutput("webcam.\(id).video", "Video", device: label, texture: processed)
        depthVideo = StreamOutput("webcam.\(id).depth", "Depth", device: label, texture: depth)
        outputs = [
            OutputSignal("\(key).motion", "Motion", device: label) { [unowned feed] _ in feed.motion },
            OutputSignal("\(key).brightness", "Brightness", device: label) { [unowned feed] _ in feed.brightness },
        ]
    }
}
