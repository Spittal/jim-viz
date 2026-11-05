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

/// A video-producing input device in the chain (Webcam, Video, Picture).
protocol VideoSourceRuntime: AnyObject, Identifiable {
    var id: String { get }
    var key: String { get }
    var bank: ParamBank { get }
    var pipeline: MTLRenderPipelineState? { get }
    var processed: MTLTexture { get }
    var outputs: [OutputSignal] { get }
    var video: StreamOutput { get }
    var depthVideo: StreamOutput { get }
    var depth: MTLTexture { get }
    var depthPipeline: MTLRenderPipelineState? { get }
    var depthHistory: MTLTexture { get }
    var depthMapped: Bool { get set }
    var sourceFeed: any VideoSourceFeed { get }
}
