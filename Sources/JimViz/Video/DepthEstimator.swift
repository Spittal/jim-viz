import CoreML
import CoreVideo
import Foundation
import Metal
import Vision

/// Estimates depth from single webcam frames with Depth Anything V2 Small (Core ML), so a
/// plain camera can drive a depth mesh. Depth is relative, not metric: 1 is the nearest thing
/// in view, 0 the farthest.
///
/// Frames come in on the capture queue; one is in flight at a time and the rest are dropped,
/// so a slow model lowers the depth rate but never backs up the camera.
final class DepthEstimator {
    enum Status: Equatable { case idle, loading, running, missingModel, failed(String) }

    /// Width of the depth grid handed to the GPU; height follows the camera's aspect.
    static let gridWidth = 192

    /// Latest depth, an r16Float texture covering the whole camera frame.
    struct Frame {
        let texture: MTLTexture
    }

    private let metal: MTLDevice
    private let queue = DispatchQueue(label: "jim-viz.depth", qos: .userInitiated)
    private let lock = NSLock()
    private var frame: Frame?
    private var busy = false
    private var request: VNCoreMLRequest?
    /// Smoothed normalization range, so depth doesn't pump when something enters the frame.
    private var lo: Float = 0, hi: Float = 1, haveRange = false
    private var lastResult = Date.distantPast
    private var lastLoadAttempt = Date.distantPast
    /// Depth textures, rewritten in turn so nothing is allocated per frame. With one result
    /// every ~30 ms, a texture is rewritten ~100 ms after it was latest, long after the GPU
    /// has read it.
    private var ring: [MTLTexture] = []
    private var ringIndex = 0
    /// Scratch, reused every frame (depth queue only).
    private var grid: [Float] = []
    private var sorted: [Float] = []
    private var pixels: [Float16] = []

    private var _status: Status = .idle
    /// Written on the depth queue; read by the UI.
    private(set) var status: Status {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }
    /// Model time per frame, in milliseconds.
    private(set) var milliseconds: Double = 0
    private(set) var framesPerSecond: Double = 0

    init(metal: MTLDevice) {
        self.metal = metal
    }

    func latest() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    /// Self-check: a depth frame from a texture instead of the model.
    func inject(_ texture: MTLTexture) {
        lock.lock(); frame = Frame(texture: texture); _status = .running; lock.unlock()
    }

    /// Clears the last depth, so a restarted feed doesn't show a stale frame.
    func reset() {
        lock.lock(); frame = nil; haveRange = false; lock.unlock()
    }

    /// Capture queue: estimate depth for this frame unless one is already in flight.
    func submit(_ buffer: CVPixelBuffer) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let request = request ?? load() else { return }
            let start = Date()
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
            } catch {
                status = .failed("Depth: \(error.localizedDescription)")
                return
            }
            guard let obs = request.results?.first as? VNPixelBufferObservation else { return }
            let now = Date()
            milliseconds = now.timeIntervalSince(start) * 1000
            let gap = now.timeIntervalSince(lastResult)
            if gap < 1 { framesPerSecond += (1 / gap - framesPerSecond) * 0.2 }
            lastResult = now
            let aspect = Float(CVPixelBufferGetHeight(buffer)) / Float(max(CVPixelBufferGetWidth(buffer), 1))
            if let tex = makeTexture(obs.pixelBuffer, aspect: aspect) {
                lock.lock(); frame = Frame(texture: tex); lock.unlock()
                status = .running
            }
        }
    }

    // MARK: Model

    /// Depth queue: loads the shared model on first use. Nil while it's missing or broken;
    /// a missing model is looked for again every few seconds, so fetching it needs no restart.
    private func load() -> VNCoreMLRequest? {
        if case .failed = status { return nil }
        if status == .missingModel, Date().timeIntervalSince(lastLoadAttempt) < 3 { return nil }
        lastLoadAttempt = Date()
        status = .loading
        do {
            guard let model = try DepthModel.shared() else { status = .missingModel; return nil }
            let r = VNCoreMLRequest(model: model)
            // The model wants 518×392; stretching the whole frame keeps every pixel's depth,
            // which matters more here than the slight squash.
            r.imageCropAndScaleOption = .scaleFill
            request = r
            return r
        } catch {
            status = .failed("Depth model: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Output

    /// Box-downsamples the model's half-float output to the grid, normalizes it to 0...1
    /// (near = 1) against a smoothed robust range, and uploads it into the next ring texture.
    private func makeTexture(_ pb: CVPixelBuffer, aspect: Float) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent16Half else {
            status = .failed("Depth model output is not half-float")
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let gw = Self.gridWidth, gh = max(2, Int((Float(gw) * aspect).rounded()))

        let count = gw * gh
        if grid.count != count {
            grid = [Float](repeating: 0, count: count)
            sorted = grid
            pixels = [Float16](repeating: 0, count: count)
        }
        for j in 0..<gh {
            let y0 = j * sh / gh, y1 = max(y0 + 1, (j + 1) * sh / gh)
            for i in 0..<gw {
                let x0 = i * sw / gw, x1 = max(x0 + 1, (i + 1) * sw / gw)
                var sum: Float = 0
                for y in y0..<y1 {
                    let line = (base + y * row).assumingMemoryBound(to: Float16.self)
                    for x in x0..<x1 { sum += Float(line[x]) }
                }
                let v = sum / Float((y1 - y0) * (x1 - x0))
                grid[j * gw + i] = v.isFinite ? v : 0
            }
        }

        // 2nd and 98th percentiles, so a few wild pixels don't squash the rest.
        for k in 0..<count { sorted[k] = grid[k] }
        sorted.sort()
        let pLo = sorted[count * 2 / 100], pHi = sorted[count * 98 / 100]
        if !haveRange { lo = pLo; hi = pHi; haveRange = true }
        else { lo += (pLo - lo) * 0.15; hi += (pHi - hi) * 0.15 }
        let span = max(hi - lo, 1e-4)
        for k in 0..<count { pixels[k] = Float16(min(max((grid[k] - lo) / span, 0), 1)) }

        if ring.first.map({ $0.width != gw || $0.height != gh }) ?? true {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: gw, height: gh, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            ring = (0..<4).compactMap { _ in metal.makeTexture(descriptor: d) }
            guard ring.count == 4 else { ring = []; return nil }
        }
        ringIndex = (ringIndex + 1) % ring.count
        let tex = ring[ringIndex]
        pixels.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, gw, gh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: gw * 2)
        }
        return tex
    }
}

/// The Core ML model, compiled and loaded once and shared by every webcam.
enum DepthModel {
    static let fileName = "DepthAnythingV2SmallF16.mlpackage"
    private static let lock = NSLock()
    private static var model: VNCoreMLModel?

    /// Where the model is looked for, in order: `JIMVIZ_MODELS`, Application Support, the app bundle.
    static var searchDirs: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["JIMVIZ_MODELS"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        dirs.append(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jim-viz/Models", isDirectory: true))
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Models", isDirectory: true)) }
        return dirs
    }

    static var packageURL: URL? {
        searchDirs.map { $0.appendingPathComponent(fileName) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Nil when the model isn't installed (scripts/fetch-depth-model.sh). Slow the very first
    /// time (about 5 s, preparing it for the Neural Engine); the compiled model is kept in
    /// Caches at a fixed path, which lets Core ML reuse that work, so later launches take ~0.1 s.
    static func shared() throws -> VNCoreMLModel? {
        lock.lock(); defer { lock.unlock() }
        if let model { return model }
        guard let url = packageURL else { return nil }
        let compiled = try compiledModel(url)
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: config))
        model = m
        return m
    }

    /// `~/Library/Caches/jim-viz/<name>.mlmodelc`, compiled again when the package is newer.
    private static func compiledModel(_ package: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("jim-viz", isDirectory: true)
        let dest = dir.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc", isDirectory: true)
        func modified(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        if let built = modified(dest), let source = modified(package), built >= source { return dest }
        let fresh = try MLModel.compileModel(at: package)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: fresh, to: dest)
        } catch {
            return fresh
        }
        return dest
    }
}
