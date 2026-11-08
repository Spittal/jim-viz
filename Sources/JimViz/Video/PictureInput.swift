import CoreGraphics
import CoreVideo
import ImageIO
import Metal
import Observation

/// Manages picture feeds, one per image file in use.
@Observable
final class PictureManager {
    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var feeds: [String: PictureFeed] = [:]

    init(device: MTLDevice) {
        metal = device
    }

    /// The feed for a picture file by path or name.
    func feed(for path: String?, store: ContentStore) -> PictureFeed {
        let key = path ?? ""
        if let f = feeds[key] { return f }
        let resolvedURL = Self.resolveURL(path, store: store)
        let f = PictureFeed(path: path, fileURL: resolvedURL, metal: metal)
        feeds[key] = f
        return f
    }

    var allFeeds: [PictureFeed] { Array(feeds.values) }

    func activate(_ active: [PictureFeed]) {
        // Picture feeds hold static textures; depth updates when depthWanted is set.
    }

    /// Resolves a path: checks absolute/tilde paths, then Content/Pictures.
    static func resolveURL(_ path: String?, store: ContentStore) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        let inContent = store.picturesDir.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: inContent.path) {
            return inContent
        }
        return nil
    }
}

/// A static image file decoded to Metal textures, plus brightness analysis.
@Observable
final class PictureFeed: VideoSourceFeed {
    enum Status: Equatable { case off, loading, running, notFound, failed(String) }

    let path: String?
    let fileURL: URL?
    private(set) var status: Status = .off

    @ObservationIgnored private let metal: MTLDevice
    @ObservationIgnored private var cache: CVMetalTextureCache?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var frame: VideoFrame?
    @ObservationIgnored private var cachedPixelBuffer: CVPixelBuffer?
    /// Brightness of the picture; a still has no motion.
    @ObservationIgnored private var luma = LumaGrid()
    var brightness: Float { luma.brightness }
    var motion: Float { luma.motion }

    @ObservationIgnored let depth: DepthEstimator
    @ObservationIgnored var depthWanted = false {
        didSet {
            if depthWanted, let pb = cachedPixelBuffer {
                depth.submit(pb)
            } else if !depthWanted {
                depth.reset()
            }
        }
    }

    init(path: String?, fileURL: URL?, metal: MTLDevice) {
        self.path = path
        self.fileURL = fileURL
        self.metal = metal
        depth = DepthEstimator(metal: metal)
        CVMetalTextureCacheCreate(nil, nil, metal, nil, &cache)
        if fileURL != nil {
            loadImage()
        } else {
            status = .notFound
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

    private func loadImage() {
        guard let url = fileURL else {
            status = .notFound
            return
        }
        status = .loading
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            status = .failed("Could not load image")
            return
        }

        let w = cgImage.width, h = cgImage.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let err = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard err == kCVReturnSuccess, let buffer = pb else {
            status = .failed("Failed to allocate pixel buffer")
            return
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            status = .failed("Could not get pixel buffer base address")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
            status = .failed("Could not create drawing context")
            return
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        cachedPixelBuffer = buffer
        receive(buffer)
    }

    private func receive(_ buffer: CVPixelBuffer) {
        guard let cache else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        luma.analyze(buffer)
        if depthWanted { depth.submit(buffer) }
        lock.lock()
        frame = VideoFrame(texture: tex, owner: cvTex)
        lock.unlock()
        setStatus(.running)
    }

    func latest() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    /// Self-check or test frame injection.
    func inject(_ texture: MTLTexture) {
        lock.lock()
        frame = VideoFrame(texture: texture, owner: nil)
        lock.unlock()
        status = .running
    }
}

/// A Picture input in the scene's Inputs section: a still image.
final class PictureRuntime: VideoSourceRuntime {
    let file: String?
    let feed: PictureFeed

    var displayName: String { file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose picture…" }

    init(id: String, file: String?, bank: ParamBank, feed: PictureFeed, gpu: VideoSourceGPU) {
        self.file = file; self.feed = feed
        let label = file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Picture"
        super.init(key: "picture.\(id)", id: id, label: label, bank: bank, feed: feed, gpu: gpu)
    }
}
