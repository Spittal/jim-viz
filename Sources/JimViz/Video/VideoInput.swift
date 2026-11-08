import AVFoundation
import CoreVideo
import Metal
import Observation

/// Manages looping video feeds, one per video file in use.
/// Feeds play when a scene that uses them is on screen and pause when none does.
@Observable
final class VideoManager {
    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var feeds: [String: VideoFeed] = [:]

    init(device: MTLDevice) {
        metal = device
    }

    /// The feed for a video file by path or name.
    func feed(for path: String?, store: ContentStore) -> VideoFeed {
        let key = path ?? ""
        if let f = feeds[key] { return f }
        let resolvedURL = Self.resolveURL(path, store: store)
        let f = VideoFeed(path: path, fileURL: resolvedURL, metal: metal)
        feeds[key] = f
        return f
    }

    var allFeeds: [VideoFeed] { Array(feeds.values) }

    /// Plays exactly these feeds; pauses the rest.
    func activate(_ active: [VideoFeed]) {
        let ids = Set(active.map(ObjectIdentifier.init))
        for f in feeds.values where !ids.contains(ObjectIdentifier(f)) { f.stop() }
        for f in active { f.play() }
    }

    /// Resolves a path: checks absolute/tilde paths, then Content/Videos.
    static func resolveURL(_ path: String?, store: ContentStore) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        let inContent = store.videosDir.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: inContent.path) {
            return inContent
        }
        return nil
    }
}

/// A looping video file decoded to Metal textures, plus brightness and motion analysis.
/// It plays between an in and an out point, set each frame by its Video input, and loops
/// back to the in point at the out point.
@Observable
final class VideoFeed: VideoSourceFeed {
    enum Status: Equatable { case off, loading, playing, notFound, failed(String) }

    let path: String?
    let fileURL: URL?
    private(set) var status: Status = .off

    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var cache: CVMetalTextureCache?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var frame: VideoFrame?
    @ObservationIgnored private(set) var wanted = false
    @ObservationIgnored private var luma = LumaGrid()
    var brightness: Float { luma.brightness }
    var motion: Float { luma.motion }

    /// In and out points as fractions of the video's length. Render thread.
    @ObservationIgnored private var range: ClosedRange<Double> = 0...1
    /// Where playback is, 0...1 of the length, for the transport bar.
    @ObservationIgnored private(set) var position: Float = 0
    /// Length in seconds, once known.
    @ObservationIgnored private var length: Double = 0
    /// Counts seeks, so only the latest one's completion clears `seeking`. Plain fields read
    /// without the lock from the seek's completion; a stale read only delays the next loop.
    @ObservationIgnored private var seekID = 0
    @ObservationIgnored private var seeking = false

    @ObservationIgnored let depth: DepthEstimator
    @ObservationIgnored var depthWanted = false {
        didSet { if !depthWanted { depth.reset() } }
    }

    init(path: String?, fileURL: URL?, metal: MTLDevice) {
        self.path = path
        self.fileURL = fileURL
        self.metal = metal
        depth = DepthEstimator(metal: metal)
        CVMetalTextureCacheCreate(nil, nil, metal, nil, &cache)
        if fileURL != nil {
            setupPlayer()
        } else {
            status = .notFound
        }
    }

    deinit {
        stop()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func setStatus(_ s: Status) {
        if Thread.isMainThread {
            if status != s { status = s }
        } else {
            DispatchQueue.main.async {
                if self.status != s { self.status = s }
            }
        }
    }

    private func setupPlayer() {
        guard let url = fileURL else {
            status = .notFound
            return
        }
        status = .loading
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(out)
        videoOutput = out

        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        p.isMuted = true
        player = p

        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { [weak self] _ in
            self?.lock.lock()
            self?.seekToIn()
            self?.lock.unlock()
        }
    }

    func play() {
        wanted = true
        guard let p = player else { return }
        p.play()
        setStatus(.playing)
    }

    func stop() {
        wanted = false
        player?.pause()
        setStatus(.off)
    }

    /// Latest frame, pulling the newest decoded video frame and looping if needed.
    func latest() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }

        if let output = videoOutput, let p = player, wanted {
            if length <= 0, let dur = p.currentItem?.duration, dur.isNumeric, dur.seconds > 0 { length = dur.seconds }
            if length > 0 {
                let t = p.currentTime().seconds
                position = Float(t / length)
                // Past the out point, or before the in point after it moved: back to the in point.
                if !seeking && (t >= range.upperBound * length || t < range.lowerBound * length - 0.05) { seekToIn() }
            }

            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime) || frame == nil {
                if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                    receive(buffer)
                }
            }
        }
        return frame
    }

    /// Render thread, each frame, from its Video's knobs: the in and out points, 0...1 of the
    /// length. Out before in plays the span between them; they're kept at least 1% apart.
    func setRange(in a: Float, out b: Float) {
        var lo = Double(min(a, b)), hi = Double(max(a, b))
        if hi - lo < 0.01 { hi = min(lo + 0.01, 1); lo = hi - 0.01 }
        lock.lock(); range = lo...hi; lock.unlock()
    }

    /// Render thread: jumps to `u` (0...1) of the way between the in and out points.
    func jump(to u: Float) {
        lock.lock(); defer { lock.unlock() }
        guard length > 0 else { return }
        seek(to: (range.lowerBound + (range.upperBound - range.lowerBound) * Double(u)) * length)
    }

    /// Holding `lock`.
    private func seekToIn() { seek(to: range.lowerBound * length) }

    /// Holding `lock`.
    private func seek(to seconds: Double) {
        guard let p = player else { return }
        seekID += 1
        let id = seekID
        seeking = true
        position = Float(length > 0 ? seconds / length : 0)
        // No lock here: a seek that replaces this one can complete it from inside `seek`.
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.seekID == id else { return }
            self.seeking = false
        }
        if wanted { p.play() }
    }

    private func receive(_ buffer: CVPixelBuffer) {
        guard let cache else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        luma.analyze(buffer)
        if depthWanted { depth.submit(buffer) }
        frame = VideoFrame(texture: tex, owner: cvTex)
        if status != .playing && wanted { setStatus(.playing) }
    }

    /// Self-check or test frame injection.
    func inject(_ texture: MTLTexture) {
        lock.lock()
        frame = VideoFrame(texture: texture, owner: nil)
        lock.unlock()
        status = .playing
    }
}

/// The Video input's transport knobs, after the video shader's: where in the file it loops.
enum VideoTransport {
    static let defs: [ParamDef] = [
        ParamDef(name: "inPoint", defaultValue: 0, min: 0, max: 1, isInt: false, group: "Transport"),
        ParamDef(name: "outPoint", defaultValue: 1, min: 0, max: 1, isInt: false, group: "Transport"),
    ]
}

/// A Video input in the scene's Inputs section. Loops a video file between its in and out
/// points. Its Jump trigger input skips to a random spot between them.
final class VideoRuntime: VideoSourceRuntime {
    let file: String?
    let feed: VideoFeed
    /// `video.<id>.jump`: each fire jumps to a random spot between the in and out points.
    let jumpTrigger: TriggerInput
    private var rng: UInt64 = 0x2545_F491_4F6C_DD1D

    var displayName: String { file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose video…" }

    init(id: String, file: String?, bank: ParamBank, feed: VideoFeed, gpu: VideoSourceGPU) {
        self.file = file; self.feed = feed
        jumpTrigger = TriggerInput("video.\(id).jump", "Jump")
        let label = file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Video"
        super.init(key: "video.\(id)", id: id, label: label, bank: bank, feed: feed, gpu: gpu)
    }

    /// Render thread, once per frame after mappings: hands the feed its in and out points, and
    /// jumps when Jump fired.
    func advanceTransport() {
        feed.setRange(in: bank.live("inPoint"), out: bank.live("outPoint"))
        guard jumpTrigger.take() else { return }
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        feed.jump(to: Float(rng >> 40) / Float(1 << 24))
    }
}
