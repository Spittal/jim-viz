import Accelerate
import Foundation

/// BeatNet's causal beat and downbeat network (Heydari, Cwitkowitz and Duan, ISMIR 2021, weights
/// CC-BY-4.0, see `Content/Models/README.md`), run on Accelerate.
///
/// Each `step` takes the latest 64 ms of 22.05 kHz mono audio, one per 20 ms hop, and returns
/// the probability that this frame is a beat and that it is a downbeat. The features match the
/// ones it was trained on (madmom's): a Hann-windowed 1411-point DFT, a 24-bands-per-octave
/// triangular filterbank from 30 Hz up, log10(1 + x), and the positive difference from the
/// previous frame. The network is a 10-tap convolution, a dense layer, two 150-cell LSTM layers
/// and a softmax: about 400k weights, roughly 20 µs a frame.
///
/// Not thread-safe; one per tracker.
final class BeatNet {
    static let sampleRate = 22050.0
    static let window = 1411
    static let hop = 441
    static let fps = sampleRate / Double(hop)
    /// The activation describes the window's centre: this long before its last sample.
    static let centreDelay = Double(window) / 2 / sampleRate

    private static let fftBins = window >> 1
    private static let bands = 136
    private static let features = 2 * bands
    private static let taps = 10
    private static let convOut = features - taps + 1
    private static let pooled = convOut / 2
    private static let hidden = 150

    // MARK: Weights

    /// The network's weights, read once from `Content/Models/beatnet.bin`.
    private final class Weights {
        let base: UnsafeMutablePointer<Float>
        let conv, convBias, dense, denseBias, out, outBias: UnsafeMutablePointer<Float>
        /// Per LSTM layer: input weights (600×150), recurrent weights (600×150), and the two
        /// biases summed.
        let wIH: [UnsafeMutablePointer<Float>], wHH: [UnsafeMutablePointer<Float>], bias: [UnsafeMutablePointer<Float>]

        init(url: URL) {
            guard let data = try? Data(contentsOf: url) else { fatalError("BeatNet weights missing: \(url.path)") }
            let h = BeatNet.hidden, g = 4 * h
            let sizes = [2 * BeatNet.taps, 2, h * 2 * BeatNet.pooled, h] + [g * h, g * h, g, g] + [g * h, g * h, g, g] + [3 * h, 3]
            let count = sizes.reduce(0, +)
            guard data.count == count * 4 else { fatalError("BeatNet weights: \(data.count) bytes, expected \(count * 4)") }
            let base = UnsafeMutablePointer<Float>.allocate(capacity: count)
            _ = data.withUnsafeBytes { memcpy(base, $0.baseAddress!, count * 4) }
            self.base = base
            var offsets: [UnsafeMutablePointer<Float>] = []
            var p = base
            for s in sizes { offsets.append(p); p += s }
            conv = offsets[0]; convBias = offsets[1]; dense = offsets[2]; denseBias = offsets[3]
            wIH = [offsets[4], offsets[8]]
            wHH = [offsets[5], offsets[9]]
            for l in 0..<2 { vDSP_vadd(offsets[6 + 4 * l], 1, offsets[7 + 4 * l], 1, offsets[6 + 4 * l], 1, vDSP_Length(g)) }
            bias = [offsets[6], offsets[10]]
            out = offsets[12]; outBias = offsets[13]
        }
    }

    private static let weights = Weights(url: ContentStore.modelsDir.appendingPathComponent("beatnet.bin"))

    // MARK: Front end

    /// The DFT's length isn't a power of two, so it's done as Bluestein's chirp-z transform:
    /// two 4096-point FFTs and a multiply by the precomputed transform of the chirp.
    private static let fftSize = 4096
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    /// Hann window × chirp, applied to the input frame.
    private var chirpRe: [Float], chirpIm: [Float]
    /// FFT of the conjugate chirp, the convolution kernel.
    private var kernelRe: [Float], kernelIm: [Float]
    /// The padded input (zero past `window`), its transform, and the convolution.
    private var aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], cRe: [Float], cIm: [Float]
    private var magnitude: [Float]
    /// Triangular filters: first FFT bin, then weights.
    private let filters: [(start: Int, weights: [Float])]

    // MARK: Network state

    private var feature: [Float]
    private var previous: [Float]
    private var hasPrevious = false
    private var conv: [Float]
    private var pooledOut: [Float]
    private var x: [Float]
    private var gates: [Float]
    private var h: [[Float]]
    private var c: [[Float]]
    private var scratch: [Float]

    init() {
        _ = Self.weights
        let n = Self.window, m = Self.fftSize
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(m), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(m), .INVERSE)!

        chirpRe = [Float](repeating: 0, count: m); chirpIm = chirpRe
        kernelRe = chirpRe; kernelIm = chirpRe
        aRe = chirpRe; aIm = chirpRe; bRe = chirpRe; bIm = chirpRe; cRe = chirpRe; cIm = chirpRe
        var kRe = chirpRe, kIm = chirpRe
        for i in 0..<n {
            // numpy's hanning: symmetric.
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            // n² mod 2N keeps the chirp's angle exact for large n.
            let theta = Double.pi * Double((i * i) % (2 * n)) / Double(n)
            chirpRe[i] = Float(hann * cos(theta))
            chirpIm[i] = Float(-hann * sin(theta))
            kRe[i] = Float(cos(theta)); kIm[i] = Float(sin(theta))
            if i > 0 { kRe[m - i] = kRe[i]; kIm[m - i] = kIm[i] }
        }
        vDSP_DFT_Execute(forward, kRe, kIm, &kernelRe, &kernelIm)
        magnitude = [Float](repeating: 0, count: Self.fftBins)
        filters = Self.makeFilters()
        precondition(filters.count == Self.bands, "BeatNet filterbank has \(filters.count) bands")

        feature = [Float](repeating: 0, count: Self.features)
        previous = [Float](repeating: 0, count: Self.bands)
        conv = [Float](repeating: 0, count: 2 * Self.convOut)
        pooledOut = [Float](repeating: 0, count: 2 * Self.pooled)
        x = [Float](repeating: 0, count: Self.hidden)
        gates = [Float](repeating: 0, count: 4 * Self.hidden)
        h = [[Float]](repeating: [Float](repeating: 0, count: Self.hidden), count: 2)
        c = h
        scratch = [Float](repeating: 0, count: Self.hidden)
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    /// Clears the LSTM's memory and the previous frame.
    func reset() {
        for l in 0..<2 {
            for i in 0..<Self.hidden { h[l][i] = 0; c[l][i] = 0 }
        }
        hasPrevious = false
    }

    /// madmom's LogarithmicFilterbank: 24 bands per octave referenced to A440, 30 Hz to 17 kHz
    /// (Nyquist caps it), centres on the nearest FFT bins with duplicates removed, overlapping
    /// triangles normalised to sum to 1.
    private static func makeFilters() -> [(start: Int, weights: [Float])] {
        let nb = fftBins
        // madmom's bin frequencies (k·sr / (2·nb)), not quite the DFT's k·sr / window.
        let binHz = (0..<nb).map { Double($0) * sampleRate / Double(2 * nb) }
        let fref = 440.0, perOctave = 24.0, fmin = 30.0, fmax = 17000.0
        let left = Int(floor(log2(fmin / fref) * perOctave)), right = Int(ceil(log2(fmax / fref) * perOctave))
        let freqs = (left..<right).map { fref * pow(2, Double($0) / perOctave) }.filter { $0 >= fmin && $0 <= fmax }
        var centres: [Int] = []
        for f in freqs {
            var i = binHz.firstIndex { $0 >= f } ?? nb
            i = min(max(i, 1), nb - 1)
            if f - binHz[i - 1] < binHz[i] - f { i -= 1 }
            if centres.last != i { centres.append(i) }
        }
        var out: [(Int, [Float])] = []
        for k in 0..<(centres.count - 2) {
            var (start, centre, stop) = (centres[k], centres[k + 1], centres[k + 2])
            if stop - start < 2 { centre = start; stop = start + 1 }
            var w = [Float](repeating: 0, count: stop - start)
            let rise = centre - start, fall = stop - centre
            for i in 0..<rise { w[i] = Float(i) / Float(rise) }
            for i in 0..<fall { w[rise + i] = 1 - Float(i) / Float(fall) }
            let sum = w.reduce(0, +)
            out.append((start, w.map { $0 / sum }))
        }
        return out
    }

    // MARK: Step

    /// One frame: `frame` holds the latest `window` samples at 22.05 kHz, oldest first.
    func step(_ frame: UnsafePointer<Float>) -> (beat: Float, downbeat: Float) {
        computeFeatures(frame)
        return runNetwork()
    }

    private func computeFeatures(_ frame: UnsafePointer<Float>) {
        let n = vDSP_Length(Self.window), m = Self.fftSize
        // a = x · window · chirp, zero-padded.
        vDSP_vmul(frame, 1, chirpRe, 1, &aRe, 1, n)
        vDSP_vmul(frame, 1, chirpIm, 1, &aIm, 1, n)
        vDSP_DFT_Execute(forward, aRe, aIm, &bRe, &bIm)
        // Multiply by the kernel's transform, back again: |X[k]| = |conv[k]| / m.
        bRe.withUnsafeMutableBufferPointer { br in
            bIm.withUnsafeMutableBufferPointer { bi in
                kernelRe.withUnsafeMutableBufferPointer { kr in
                    kernelIm.withUnsafeMutableBufferPointer { ki in
                        var b = DSPSplitComplex(realp: br.baseAddress!, imagp: bi.baseAddress!)
                        var k = DSPSplitComplex(realp: kr.baseAddress!, imagp: ki.baseAddress!)
                        vDSP_zvmul(&b, 1, &k, 1, &b, 1, vDSP_Length(m), 1)
                    }
                }
            }
        }
        vDSP_DFT_Execute(inverse, bRe, bIm, &cRe, &cIm)
        cRe.withUnsafeMutableBufferPointer { ar in
            cIm.withUnsafeMutableBufferPointer { ai in
                var z = DSPSplitComplex(realp: ar.baseAddress!, imagp: ai.baseAddress!)
                vDSP_zvabs(&z, 1, &magnitude, 1, vDSP_Length(Self.fftBins))
            }
        }
        var scale = 1 / Float(m)
        vDSP_vsmul(magnitude, 1, &scale, &magnitude, 1, vDSP_Length(Self.fftBins))

        // Filterbank, log, and the positive difference from the previous frame.
        magnitude.withUnsafeBufferPointer { mag in
            for (j, f) in filters.enumerated() {
                var s: Float = 0
                vDSP_dotpr(mag.baseAddress! + f.start, 1, f.weights, 1, &s, vDSP_Length(f.weights.count))
                feature[j] = log10(1 + s)
            }
        }
        let b = Self.bands
        for j in 0..<b {
            feature[b + j] = hasPrevious ? max(0, feature[j] - previous[j]) : 0
            previous[j] = feature[j]
        }
        hasPrevious = true
    }

    private func runNetwork() -> (beat: Float, downbeat: Float) {
        let w = Self.weights
        let hid = Self.hidden, g = 4 * hid
        // Two-filter convolution, ReLU, max-pool by 2, flattened channel by channel.
        for o in 0..<2 {
            conv.withUnsafeMutableBufferPointer { cv in
                let out = cv.baseAddress! + o * Self.convOut
                vDSP_conv(feature, 1, w.conv + o * Self.taps, 1, out, 1, vDSP_Length(Self.convOut), vDSP_Length(Self.taps))
                var bias = w.convBias[o], zero: Float = 0
                vDSP_vsadd(out, 1, &bias, out, 1, vDSP_Length(Self.convOut))
                vDSP_vthres(out, 1, &zero, out, 1, vDSP_Length(Self.convOut))
                pooledOut.withUnsafeMutableBufferPointer { p in
                    vDSP_vmax(out, 2, out + 1, 2, p.baseAddress! + o * Self.pooled, 1, vDSP_Length(Self.pooled))
                }
            }
        }
        // Dense layer.
        memcpy(&x, w.denseBias, hid * 4)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(hid), Int32(2 * Self.pooled), 1, w.dense, Int32(2 * Self.pooled),
                    pooledOut, 1, 1, &x, 1)
        // Two LSTM layers. Gates are in PyTorch's order: input, forget, cell, output.
        // σ(v) = ½·tanh(½v) + ½, so one vvtanhf covers every gate.
        for l in 0..<2 {
            memcpy(&gates, w.bias[l], g * 4)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(g), Int32(hid), 1, w.wIH[l], Int32(hid), x, 1, 1, &gates, 1)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(g), Int32(hid), 1, w.wHH[l], Int32(hid), h[l], 1, 1, &gates, 1)
            gates.withUnsafeMutableBufferPointer { gp in
                let p = gp.baseAddress!
                var half: Float = 0.5
                vDSP_vsmul(p, 1, &half, p, 1, vDSP_Length(2 * hid))
                vDSP_vsmul(p + 3 * hid, 1, &half, p + 3 * hid, 1, vDSP_Length(hid))
                var count = Int32(g)
                vvtanhf(p, p, &count)
                vDSP_vsmsa(p, 1, &half, &half, p, 1, vDSP_Length(2 * hid))
                vDSP_vsmsa(p + 3 * hid, 1, &half, &half, p + 3 * hid, 1, vDSP_Length(hid))
                let n = vDSP_Length(hid)
                // c = f·c + i·g; h = o·tanh(c).
                c[l].withUnsafeMutableBufferPointer { cp in
                    vDSP_vmul(cp.baseAddress!, 1, p + hid, 1, cp.baseAddress!, 1, n)
                    vDSP_vma(p, 1, p + 2 * hid, 1, cp.baseAddress!, 1, cp.baseAddress!, 1, n)
                    var cnt = Int32(hid)
                    vvtanhf(&scratch, cp.baseAddress!, &cnt)
                }
                h[l].withUnsafeMutableBufferPointer { hp in
                    vDSP_vmul(p + 3 * hid, 1, scratch, 1, hp.baseAddress!, 1, n)
                }
            }
            h[l].withUnsafeBufferPointer { hp in _ = memcpy(&x, hp.baseAddress!, hid * 4) }
        }
        // Output layer and softmax over beat, downbeat, neither.
        var z0: Float = 0, z1: Float = 0, z2: Float = 0
        vDSP_dotpr(w.out, 1, x, 1, &z0, vDSP_Length(hid))
        vDSP_dotpr(w.out + hid, 1, x, 1, &z1, vDSP_Length(hid))
        vDSP_dotpr(w.out + 2 * hid, 1, x, 1, &z2, vDSP_Length(hid))
        z0 += w.outBias[0]; z1 += w.outBias[1]; z2 += w.outBias[2]
        let top = max(z0, z1, z2)
        let e0 = exp(z0 - top), e1 = exp(z1 - top), e2 = exp(z2 - top)
        let sum = e0 + e1 + e2
        return (e0 / sum, e1 / sum)
    }
}
