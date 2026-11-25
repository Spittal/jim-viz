import Foundation
import simd

/// A pose of the Dancer's skeleton: where the hips are, in hip heights over the floor (1 is
/// standing straight), and each joint's turn from its parent's.
struct MotionPose {
    var root = SIMD3<Float>(0, 1, 0)
    var rotations = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: DancerModel.jointCount)
}

/// A baked motion-capture clip (scripts/bake-motion.py writes them, and describes the file): a
/// performance, a pose a frame on the Dancer's skeleton at 30 fps, and the beat it was danced to. Unpacked
/// once, when loaded, into 16-bit values; played between frames on Catmull-Rom curves, which
/// is as good as the 60 fps it was captured at (the bake smooths away anything faster).
final class MotionClip {
    let name: String
    let frames: Int
    let fps: Float, bpm: Float
    /// When its first beat falls, in seconds, and how many beats it plays (whole bars).
    let firstBeat: Float, beats: Float
    /// A frame: the hips' position in 1/4096 hip heights, then each joint's quaternion (x, y, z,
    /// w) in 1/32767, each joint's kept on one side of the sphere through time.
    private static let channels = 3 + DancerModel.jointCount * 4
    private let values: [Int16]

    init(_ url: URL) {
        name = url.deletingPathExtension().lastPathComponent
        let header = 32
        guard let data = try? Data(contentsOf: url), data.count >= header, data.prefix(4) == Data("JVMC".utf8)
        else { fatalError("Motion clip invalid: \(url.path)") }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        func f32(_ at: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Float.self) } }
        let frames = Int(u32(4)), channels = Self.channels
        self.frames = frames; fps = f32(8); bpm = f32(12); firstBeat = f32(16); beats = f32(20)
        let count = frames * channels
        guard u32(24) == DancerModel.jointCount, frames > 3, fps > 0, bpm > 0, beats >= 4,
              data.count == header + Int(u32(28)),
              let packed = try? (data.subdata(in: header..<data.count) as NSData).decompressed(using: .zlib) as Data,
              packed.count == count * 2 else { fatalError("Motion clip invalid: \(url.path)") }
        // Low bytes, then high bytes, of each channel's second differences through time.
        var out = [Int16](repeating: 0, count: count)
        packed.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for c in 0..<channels {
                var value: Int16 = 0, step: Int16 = 0
                for f in 0..<frames {
                    let k = c * frames + f
                    let d = Int16(bitPattern: UInt16(bytes[k]) | UInt16(bytes[count + k]) << 8)
                    if f == 0 { value = d; step = d } else { step &+= d; value &+= step }
                    out[f * channels + c] = value
                }
            }
        }
        values = out
    }

    /// The pose `seconds` in, on a Catmull-Rom curve through the frames either side. Render
    /// thread; allocates nothing.
    func sample(_ seconds: Float, into pose: inout MotionPose) {
        let f = min(max(seconds * fps, 0), Float(frames - 1))
        let i = min(Int(f), frames - 2), t = f - Float(i)
        let k0 = max(i - 1, 0) * Self.channels, k1 = i * Self.channels, k2 = k1 + Self.channels
        let k3 = min(i + 2, frames - 1) * Self.channels
        let w0 = ((-t + 2) * t - 1) * t * 0.5, w1 = ((3 * t - 5) * t * t + 2) * 0.5
        let w2 = ((-3 * t + 4) * t + 1) * t * 0.5, w3 = (t - 1) * t * t * 0.5
        values.withUnsafeBufferPointer { v in
            func curve(_ c: Int) -> Float { Float(v[k0 + c]) * w0 + Float(v[k1 + c]) * w1 + Float(v[k2 + c]) * w2 + Float(v[k3 + c]) * w3 }
            pose.root = SIMD3(curve(0), curve(1), curve(2)) / 4096
            for j in 0..<DancerModel.jointCount {
                let c = 3 + j * 4
                let q = SIMD4(curve(c), curve(c + 1), curve(c + 2), curve(c + 3))
                pose.rotations[j] = simd_quatf(vector: simd_normalize(q))
            }
        }
    }
}

/// The Dancer's styles and the performances that dance them: a folder a style in the content's
/// `Motion`, baked from AIST++'s advanced dances by scripts/bake-motion.py.
enum MotionLibrary {
    /// The `style` knob's steps, as folder names. Must match dancer.metal's labels and the baker's.
    static let styles = ["hiphop", "lahiphop", "house", "popping", "locking", "waacking", "krump", "break", "streetjazz", "balletjazz"]

    /// Each style's clips, by name. Read once, when the first Dancer is built.
    static let clips: [[MotionClip]] = styles.map { style in
        let urls = (try? FileManager.default.contentsOfDirectory(at: ContentStore.motionDir.appendingPathComponent(style),
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jvmc" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(MotionClip.init)
    }
}
