import CoreVideo
import Metal

/// A video frame texture ready for GPU processing. `owner` keeps the pixel buffer alive
/// while the GPU reads it.
struct VideoFrame {
    let texture: MTLTexture
    let owner: AnyObject?
}

/// A visual feed (webcam, video file, picture) that supplies frames and depth estimation.
protocol VideoSourceFeed: AnyObject {
    var brightness: Float { get }
    var motion: Float { get }
    var depth: DepthEstimator { get }
    var depthWanted: Bool { get set }
    func latest() -> VideoFrame?
    func inject(_ texture: MTLTexture)
}

/// Average brightness and frame-to-frame change of a feed's BGRA frames, read on a coarse
/// 32 × 18 grid. The grid is kept between frames, so analysing one allocates nothing.
struct LumaGrid {
    private(set) var brightness: Float = 0
    private(set) var motion: Float = 0
    private static let columns = 32, rows = 18
    private var grid = [Float](repeating: 0, count: columns * rows)
    private var previous = [Float](repeating: 0, count: columns * rows)
    private var hasPrevious = false

    mutating func analyze(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let gx = Self.columns, gy = Self.rows
        swap(&grid, &previous)
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
        if hasPrevious {
            var diff: Float = 0
            for k in grid.indices { diff += abs(grid[k] - previous[k]) }
            motion += (min(diff / Float(grid.count) * 8, 1) - motion) * 0.5
        }
        hasPrevious = true
    }
}

/// The GPU side of a video source: the webcam processing pipelines from
/// `Shaders/inputs/webcam.metal`, and the textures they write. Made when the source is built
/// and carried over when the chain is edited, so the render thread never allocates them.
struct VideoSourceGPU {
    let pipeline: MTLRenderPipelineState?
    let depthPipeline: MTLRenderPipelineState?
    let processed: MTLTexture
    let depth: MTLTexture
    let depthHistory: MTLTexture
}

/// A video-producing input in the scene's Inputs section: a Webcam, a Video or a Picture. Its
/// knobs (from `Shaders/inputs/webcam.metal`) process the feed into `processed`, which is its
/// video output; motion and brightness are value outputs. Its second video output, Depth, is
/// estimated from the image (white = near) and drawn by `depthPipeline` into `depth`, with
/// `depthHistory` holding last frame's for smoothing. The model runs only while `depthMapped`.
class VideoSourceRuntime: Identifiable {
    let id: String
    /// Chain key: `webcam.<id>`, `video.<id>` or `picture.<id>`.
    let key: String
    let bank: ParamBank
    let sourceFeed: any VideoSourceFeed
    let pipeline: MTLRenderPipelineState?
    let processed: MTLTexture
    let depthPipeline: MTLRenderPipelineState?
    let depth: MTLTexture
    let depthHistory: MTLTexture
    /// `<key>.video` and `<key>.depth`.
    let video: StreamOutput
    let depthVideo: StreamOutput
    /// `<key>.motion` and `<key>.brightness`.
    let outputs: [OutputSignal]
    /// Set when the scene maps the Depth output somewhere; only then does the model run.
    var depthMapped = false

    init(key: String, id: String, label: String, bank: ParamBank, feed: any VideoSourceFeed, gpu: VideoSourceGPU) {
        self.key = key; self.id = id; self.bank = bank; sourceFeed = feed
        pipeline = gpu.pipeline; processed = gpu.processed
        depthPipeline = gpu.depthPipeline; depth = gpu.depth; depthHistory = gpu.depthHistory
        video = StreamOutput("\(key).video", "Video", device: label, texture: processed)
        depthVideo = StreamOutput("\(key).depth", "Depth", device: label, texture: depth)
        outputs = [
            OutputSignal("\(key).motion", "Motion", device: label) { [unowned feed] _ in feed.motion },
            OutputSignal("\(key).brightness", "Brightness", device: label) { [unowned feed] _ in feed.brightness },
        ]
    }
}
