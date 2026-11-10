import Accelerate
import Foundation

/// StemgenRT's causal stem separation, run on Accelerate: drums, bass and vocals each come from
/// their own small network, and other is the input minus the three.
/// Model: https://github.com/sweetspotsoundsystem/stemgen-rt, weights CC BY-NC-SA 4.0 by Axel
/// Delafosse / StemgenRT (non-commercial; see `Content/Models/README.md`), converted by
/// scripts/export-stemgen.py.
///
/// Each network takes a 1024-point spectrum of the latest audio, encodes it into bands, runs a
/// GRU per band and a global GRU across them (two layers), and predicts a complex mask, which
/// is applied and turned back into audio by overlap-add. Drums adds a small waveform branch;
/// bass also looks at a 4096-point spectrum.
///
/// `step` takes 128 new samples at 44.1 kHz and returns the stems of the previous 128, so a stem
/// lags its audio by 256 samples (5.8 ms) counting the wait for the hop.
///
/// The capture is mono, so the stereo networks run with left = right and their two output
/// channels are averaged, which is folded into the weights when they load: the same result for
/// half the work. All three share one spectrum. Not thread-safe; one per capture.
final class StemSeparator {
    enum Stem: Int, CaseIterable {
        case drums, bass, vocals, other
        var name: String { ["Drums", "Bass", "Vocals", "Other"][rawValue] }
        /// Its part of Audio In's output keys: `audio.drumsStem`, `audio.drumsSpectrum`.
        var key: String { ["drums", "bass", "vocals", "other"][rawValue] }
    }

    static let sampleRate = 44100.0
    static let hop = 128

    fileprivate static let bins = 513
    fileprivate static let longSize = 4096, longBins = 2049

    private let models: [Model]
    /// The latest 4096 samples, oldest first; the long analysis needs them all.
    private var history = [Float](repeating: 0, count: longSize)
    /// The previous hop's input, which this step's stems describe.
    private var previous = [Float](repeating: 0, count: hop)
    private let front = FrontEnd()

    init(weights: Weights) {
        models = weights.models.map(Model.init)
    }

    /// Clears every network's memory and the audio history.
    func reset() {
        for i in history.indices { history[i] = 0 }
        for i in previous.indices { previous[i] = 0 }
        for m in models { m.reset() }
    }

    /// Takes `hop` new samples and writes the stems of the previous hop to `out`: `hop`
    /// samples each, in `Stem` order.
    func step(_ input: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
        let h = Self.hop, n = Self.longSize
        history.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress!
            memmove(p, p + h, (n - h) * 4)
            memcpy(p + n - h, input, h * 4)
            front.analyse(p)
            for (i, m) in models.enumerated() { m.step(front, latest: p + n - 256, out + i * h) }
        }
        // Other: the input those stems describe, minus them.
        let other = out + 3 * h
        memcpy(other, previous, h * 4)
        for i in 0..<3 { vDSP_vsub(out + i * h, 1, other, 1, other, 1, vDSP_Length(h)) }
        memcpy(&previous, input, h * 4)
    }

    // MARK: Weights

    /// The three networks' weights, read from `Content/Models/stemgen.bin` on first use (32 MB).
    final class Weights {
        fileprivate let models: [ModelWeights]
        private let base: UnsafeMutablePointer<Float>

        static let shared = Weights(url: ContentStore.modelsDir.appendingPathComponent("stemgen.bin"))

        private init(url: URL) {
            guard let data = try? Data(contentsOf: url) else { fatalError("Stem model unreadable: \(url.path)") }
            let geometries = Geometry.all
            let count = geometries.map(\.weightCount).reduce(0, +)
            guard data.count == count * 4 else { fatalError("Stem model: \(data.count) bytes, expected \(count * 4)") }
            let base = Floats.allocate(capacity: count)
            _ = data.withUnsafeBytes { memcpy(base, $0.baseAddress!, count * 4) }
            self.base = base
            var cursor = base
            models = geometries.map { g in
                defer { cursor += g.weightCount }
                return ModelWeights(g, cursor)
            }
        }
    }
}

/// One network's shape. Bands split the 513 spectrum bins (`edges`); each band is encoded to
/// `bandWidth` values, and the global GRU has `globalWidth`.
private struct Geometry {
    let bandWidth: Int
    let globalWidth: Int
    let edges: [Int]
    /// Bass: also encodes a 4096-point magnitude spectrum, banded at 4× the edges.
    let long: Bool
    /// Drums: a waveform branch of this many basis channels on the latest 256 samples.
    let basis: Int

    static let edges = [0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 160, 192, 240, 288, 352, 416, 513]
    static let bassEdges = [0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 160, 256, 384, 513]
    /// In `stemgen.bin`'s order: drums, bass, vocals.
    static let all = [
        Geometry(bandWidth: 96, globalWidth: 192, edges: edges, long: false, basis: 256),
        Geometry(bandWidth: 80, globalWidth: 160, edges: bassEdges, long: true, basis: 0),
        Geometry(bandWidth: 96, globalWidth: 192, edges: edges, long: false, basis: 0),
    ]

    var bands: Int { edges.count - 1 }
    func width(_ b: Int) -> Int { edges[b + 1] - edges[b] }
    var longEdges: [Int] { edges.map { min($0 * 4, StemSeparator.longBins) } }
    func longWidth(_ b: Int) -> Int { longEdges[b + 1] - longEdges[b] }

    /// Floats in the file, in the order `scripts/export-stemgen.py` writes.
    var weightCount: Int {
        let bw = bandWidth, gw = globalWidth, nb = bands
        var n = (0..<nb).map { bw * 6 * width($0) + bw }.reduce(0, +)
        if long { n += (0..<nb).map { bw * 2 * longWidth($0) }.reduce(0, +) }
        n += nb * bw + bw
        n += 2 * (2 * 3 * bw * bw + 2 * 3 * bw + bw + gw * nb * bw + gw + 2 * 3 * gw * gw + 2 * 3 * gw + gw + nb * bw * gw + nb * bw)
        n += nb * (bw * bw + bw)
        n += (0..<nb).map { 4 * width($0) * bw + 4 * width($0) }.reduce(0, +)
        if basis > 0 { n += basis * 512 + basis * gw + basis + 512 * basis }
        return n
    }
}

private typealias Floats = UnsafeMutablePointer<Float>

/// One network's weights: pointers into the file, plus the mono-folded copies of the maps that
/// read or write the two channels.
private final class ModelWeights {
    let g: Geometry
    struct Layer {
        let wIH, wHH, bIH, bHH, localNorm, globalIn, globalInBias: Floats
        let gIH, gHH, gbIH, gbHH, globalNorm, globalOut, globalOutBias: Floats
    }
    /// Per band: encoder (bandWidth × 3w, channels summed), bias.
    let encoders: [(Floats, Floats)]
    /// Bass, per band: long encoder (bandWidth × lw, channels summed).
    let longEncoders: [Floats]
    let identity, inputNorm: Floats
    let layers: [Layer]
    /// Per band: mask hidden (bandWidth²), bias; mask head (2w × bandWidth, channels averaged), bias.
    let maskHidden: [(Floats, Floats)]
    let heads: [(Floats, Floats)]
    /// Drums: waveform encode (basis × 256, channels summed), gates (basis × globalWidth), gates
    /// bias, decode (256 × basis, channels averaged).
    let waveEncode, waveGates, waveGatesBias, waveDecode: Floats?

    init(_ g: Geometry, _ start: Floats) {
        self.g = g
        var p = start
        func take(_ n: Int) -> Floats { defer { p += n }; return p }
        let bw = g.bandWidth, gw = g.globalWidth, nb = g.bands
        encoders = (0..<nb).map { b in
            let w = g.width(b)
            return (Self.sumHalves(take(bw * 6 * w), rows: bw, half: 3 * w), take(bw))
        }
        longEncoders = g.long ? (0..<nb).map { Self.sumHalves(take(bw * 2 * g.longWidth($0)), rows: bw, half: g.longWidth($0)) } : []
        identity = take(nb * bw); inputNorm = take(bw)
        layers = (0..<2).map { _ in
            Layer(wIH: take(3 * bw * bw), wHH: take(3 * bw * bw), bIH: take(3 * bw), bHH: take(3 * bw),
                  localNorm: take(bw), globalIn: take(gw * nb * bw), globalInBias: take(gw),
                  gIH: take(3 * gw * gw), gHH: take(3 * gw * gw), gbIH: take(3 * gw), gbHH: take(3 * gw),
                  globalNorm: take(gw), globalOut: take(nb * bw * gw), globalOutBias: take(nb * bw))
        }
        maskHidden = (0..<nb).map { _ in (take(bw * bw), take(bw)) }
        heads = (0..<nb).map { b in
            let w = g.width(b)
            return (Self.averageHalves(take(4 * w * bw), rows: 2 * w, cols: bw), Self.averageHalves(take(4 * w), rows: 2 * w, cols: 1))
        }
        if g.basis > 0 {
            waveEncode = Self.sumHalves(take(g.basis * 512), rows: g.basis, half: 256)
            waveGates = take(g.basis * gw); waveGatesBias = take(g.basis)
            waveDecode = Self.averageHalves(take(512 * g.basis), rows: 256, cols: g.basis)
        } else {
            waveEncode = nil; waveGates = nil; waveGatesBias = nil; waveDecode = nil
        }
        precondition(p - start == g.weightCount)
    }

    /// A map whose input is [left half, right half] (`rows` × 2·`half`), as one that takes the
    /// mono signal for both: the halves summed.
    static func sumHalves(_ w: Floats, rows: Int, half: Int) -> Floats {
        let out = Floats.allocate(capacity: rows * half)
        for r in 0..<rows { vDSP_vadd(w + r * 2 * half, 1, w + r * 2 * half + half, 1, out + r * half, 1, vDSP_Length(half)) }
        return out
    }

    /// A map whose output is [left rows, right rows] (2·`rows` × `cols`), as one that gives the
    /// average of the two.
    static func averageHalves(_ w: Floats, rows: Int, cols: Int) -> Floats {
        let n = rows * cols
        let out = Floats.allocate(capacity: n)
        var half: Float = 0.5
        vDSP_vasm(w, 1, w + n, 1, &half, out, 1, vDSP_Length(n))
        return out
    }
}

/// The spectrum all three networks read, and its features. Recomputed each hop.
private final class FrontEnd {
    private let fft = FFT(log2n: 10), longFFT = FFT(log2n: 12)
    /// The asymmetric analysis window (Wang et al., arXiv:2106.11794: K 1024, M 128).
    private let analysis = Floats.allocate(capacity: 1024)
    private let hann4096 = Floats.allocate(capacity: 4096)
    /// The latest 1024 samples' spectrum at true DFT scale, 513 bins.
    let re = Floats.allocate(capacity: StemSeparator.bins), im = Floats.allocate(capacity: StemSeparator.bins)
    /// Per bin, interleaved: re/scale, im/scale, log1p(|X|/scale), where scale is the RMS magnitude.
    let features = Floats.allocate(capacity: 3 * StemSeparator.bins)
    /// log1p(|X|/scale) of the latest 4096 samples' spectrum (Hann window), 2049 bins.
    let longFeatures = Floats.allocate(capacity: StemSeparator.longBins)
    private let frame = Floats.allocate(capacity: StemSeparator.longSize)
    private let longRe = Floats.allocate(capacity: StemSeparator.longBins), longIm = Floats.allocate(capacity: StemSeparator.longBins)
    private let logMagnitude = Floats.allocate(capacity: StemSeparator.bins)

    init() {
        for n in 0..<1024 {
            analysis[n] = Float(n < 896 ? sin(Double.pi * Double(n) / 1792) : cos(Double.pi * Double(n - 896) / 256))
        }
        for n in 0..<4096 { hann4096[n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / 4096)) }
    }

    /// `history`: the latest 4096 samples, oldest first.
    func analyse(_ history: UnsafePointer<Float>) {
        let nb = StemSeparator.bins
        vDSP_vmul(history + 3072, 1, analysis, 1, frame, 1, 1024)
        fft.forward(frame, re, im)
        var inv = 1 / Self.logMagnitude(re, im, nb, into: logMagnitude)
        vDSP_vsmul(re, 1, &inv, features, 3, vDSP_Length(nb))
        vDSP_vsmul(im, 1, &inv, features + 1, 3, vDSP_Length(nb))
        cblas_scopy(Int32(nb), logMagnitude, 1, features + 2, 3)

        vDSP_vmul(history, 1, hann4096, 1, frame, 1, 4096)
        longFFT.forward(frame, longRe, longIm)
        _ = Self.logMagnitude(longRe, longIm, StemSeparator.longBins, into: longFeatures)
    }

    /// Writes log1p(√(|X|² + 1e-12) / scale) per bin to `out`, where scale = √max(mean |X|², 1e-8),
    /// and returns scale.
    private static func logMagnitude(_ re: Floats, _ im: Floats, _ n: Int, into out: Floats) -> Float {
        vDSP_vmma(re, 1, re, 1, im, 1, im, 1, out, 1, vDSP_Length(n))
        var mean: Float = 0
        vDSP_meanv(out, 1, &mean, vDSP_Length(n))
        let scale = max(mean, 1e-8).squareRoot()
        var eps: Float = 1e-12, inv = 1 / scale, count = Int32(n)
        vDSP_vsadd(out, 1, &eps, out, 1, vDSP_Length(n))
        vvsqrtf(out, out, &count)
        vDSP_vsmul(out, 1, &inv, out, 1, vDSP_Length(n))
        vvlog1pf(out, out, &count)
        return scale
    }
}

/// A real FFT of 2^log2n points returning bins 0...N/2 at true DFT scale, and its inverse.
private final class FFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var packedRe: [Float], packedIm: [Float]

    init(log2n: Int) {
        self.log2n = vDSP_Length(log2n)
        n = 1 << log2n
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        packedRe = [Float](repeating: 0, count: n / 2); packedIm = packedRe
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `x`: n samples. `re`, `im`: n/2 + 1 bins.
    func forward(_ x: UnsafePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        let h = n / 2
        packedRe.withUnsafeMutableBufferPointer { pr in
            packedIm.withUnsafeMutableBufferPointer { pi in
                var z = DSPSplitComplex(realp: pr.baseAddress!, imagp: pi.baseAddress!)
                x.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(h)) }
                vDSP_fft_zrip(setup, &z, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's forward transform is twice the DFT; DC and Nyquist share element 0.
                var half: Float = 0.5
                vDSP_vsmul(pr.baseAddress!, 1, &half, re, 1, vDSP_Length(h))
                vDSP_vsmul(pi.baseAddress!, 1, &half, im, 1, vDSP_Length(h))
                re[h] = im[0]; im[h] = 0; im[0] = 0
            }
        }
    }

    /// The inverse of n/2 + 1 bins (imaginary parts of DC and Nyquist ignored) into n samples.
    func inverse(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ x: UnsafeMutablePointer<Float>) {
        let h = n / 2
        packedRe.withUnsafeMutableBufferPointer { pr in
            packedIm.withUnsafeMutableBufferPointer { pi in
                memcpy(pr.baseAddress!, re, h * 4)
                memcpy(pi.baseAddress!, im, h * 4)
                pi[0] = re[h]
                var z = DSPSplitComplex(realp: pr.baseAddress!, imagp: pi.baseAddress!)
                vDSP_fft_zrip(setup, &z, 1, log2n, FFTDirection(FFT_INVERSE))
                x.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&z, 1, $0, 2, vDSP_Length(h)) }
                var scale = 1 / Float(n)
                vDSP_vsmul(x, 1, &scale, x, 1, vDSP_Length(n))
            }
        }
    }
}

/// One stem's network and its memory.
private final class Model {
    private let w: ModelWeights
    // Memory carried between hops.
    private let local: [Floats]     // per layer: bands × bandWidth
    private let global: [Floats]    // per layer: globalWidth
    private let spectralTail = Floats.allocate(capacity: 128)
    private let waveTail = Floats.allocate(capacity: 128)
    // Scratch.
    private let bands, encoded, gi, gh, projected, ggi, ggh, shared, hidden, head: Floats
    private let maskRe = Floats.allocate(capacity: StemSeparator.bins), maskIm = Floats.allocate(capacity: StemSeparator.bins)
    private let time = Floats.allocate(capacity: 1024)
    private let synthesis = Floats.allocate(capacity: 256), denominator = Floats.allocate(capacity: 128)
    private let hann256 = Floats.allocate(capacity: 256)
    private let basis, gates, decoded: Floats
    private let inverse = FFT(log2n: 10)

    init(_ w: ModelWeights) {
        self.w = w
        let g = w.g, bw = g.bandWidth, gw = g.globalWidth, nb = g.bands
        func zeros(_ n: Int) -> Floats { let p = Floats.allocate(capacity: n); p.initialize(repeating: 0, count: n); return p }
        local = (0..<2).map { _ in zeros(nb * bw) }
        global = (0..<2).map { _ in zeros(gw) }
        bands = zeros(nb * bw); encoded = zeros(nb * bw)
        gi = zeros(nb * 3 * max(bw, gw)); gh = zeros(nb * 3 * max(bw, gw))
        projected = zeros(gw); ggi = zeros(3 * gw); ggh = zeros(3 * gw); shared = zeros(gw)
        hidden = zeros(bw); head = zeros(2 * StemSeparator.bins)
        basis = zeros(max(g.basis, 1)); gates = zeros(max(g.basis, 1)); decoded = zeros(256)
        // The synthesis window and overlap divisor that undo the analysis window (dsp.py).
        let analysis = (0..<1024).map { n in n < 896 ? sin(Double.pi * Double(n) / 1792) : cos(Double.pi * Double(n - 896) / 256) }
        let proto = (0..<256).map { 0.5 * (1 - cos(Double.pi * Double($0) / 128)) }
        var syn = [Double](repeating: 0, count: 256)
        for i in 0..<128 { syn[i] = proto[i] / analysis[768 + i]; syn[128 + i] = analysis[896 + i] }
        for i in 0..<256 { synthesis[i] = Float(syn[i]) }
        for i in 0..<128 { denominator[i] = Float(analysis[768 + i] * syn[i] + analysis[896 + i] * syn[128 + i]) }
        for i in 0..<256 { hann256[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 256)) }
        reset()
    }

    func reset() {
        let g = w.g
        for p in local { p.update(repeating: 0, count: g.bands * g.bandWidth) }
        for p in global { p.update(repeating: 0, count: g.globalWidth) }
        spectralTail.update(repeating: 0, count: 128)
        waveTail.update(repeating: 0, count: 128)
    }

    /// One hop: reads the shared spectrum and the latest 256 samples, writes 128 samples of this stem.
    func step(_ f: FrontEnd, latest: UnsafePointer<Float>, _ out: Floats) {
        let g = w.g, bw = g.bandWidth, gw = g.globalWidth, nb = g.bands

        // Encode each band of features, plus bass's long-spectrum features.
        for b in 0..<nb {
            let (m, bias) = w.encoders[b]
            let width = 3 * g.width(b)
            memcpy(encoded + b * bw, bias, bw * 4)
            gemv(m, rows: bw, cols: width, f.features + 3 * g.edges[b], into: encoded + b * bw)
            if g.long {
                let le = g.longEdges
                gemv(w.longEncoders[b], rows: bw, cols: le[b + 1] - le[b], f.longFeatures + le[b], into: encoded + b * bw)
            }
        }
        silu(encoded, nb * bw)
        vDSP_vadd(encoded, 1, w.identity, 1, bands, 1, vDSP_Length(nb * bw))
        for b in 0..<nb { rmsNorm(bands + b * bw, bw, w.inputNorm) }

        for (l, layer) in w.layers.enumerated() {
            // A GRU per band (shared weights, each its own memory), then a residual and norm.
            gru(bands, local[l], rows: nb, width: bw, layer.wIH, layer.wHH, layer.bIH, layer.bHH)
            vDSP_vadd(bands, 1, local[l], 1, bands, 1, vDSP_Length(nb * bw))
            for b in 0..<nb { rmsNorm(bands + b * bw, bw, layer.localNorm) }
            // The global GRU across all bands, fed back into each.
            memcpy(projected, layer.globalInBias, gw * 4)
            gemv(layer.globalIn, rows: gw, cols: nb * bw, bands, into: projected)
            gru(projected, global[l], rows: 1, width: gw, layer.gIH, layer.gHH, layer.gbIH, layer.gbHH)
            vDSP_vadd(projected, 1, global[l], 1, shared, 1, vDSP_Length(gw))
            rmsNorm(shared, gw, layer.globalNorm)
            vDSP_vadd(bands, 1, layer.globalOutBias, 1, bands, 1, vDSP_Length(nb * bw))
            gemv(layer.globalOut, rows: nb * bw, cols: gw, shared, into: bands)
        }

        // Each band's mask: real and imaginary per bin.
        for b in 0..<nb {
            let (mh, mhBias) = w.maskHidden[b], (hw, hBias) = w.heads[b]
            let width = g.width(b)
            memcpy(hidden, mhBias, bw * 4)
            gemv(mh, rows: bw, cols: bw, bands + b * bw, into: hidden)
            silu(hidden, bw)
            memcpy(head, hBias, 2 * width * 4)
            gemv(hw, rows: 2 * width, cols: bw, hidden, into: head)
            cblas_scopy(Int32(width), head, 2, maskRe + g.edges[b], 1)
            cblas_scopy(Int32(width), head + 1, 2, maskIm + g.edges[b], 1)
        }

        // Apply it, back to audio, and overlap-add the last 256 samples of the frame.
        let n = vDSP_Length(StemSeparator.bins)
        var x = DSPSplitComplex(realp: f.re, imagp: f.im), m = DSPSplitComplex(realp: maskRe, imagp: maskIm)
        vDSP_zvmul(&x, 1, &m, 1, &m, 1, n, 1)
        inverse.inverse(maskRe, maskIm, time)
        vDSP_vmul(time + 768, 1, synthesis, 1, time + 768, 1, 256)
        vDSP_vadd(time + 768, 1, spectralTail, 1, out, 1, 128)
        vDSP_vdiv(denominator, 1, out, 1, out, 1, 128)
        memcpy(spectralTail, time + 896, 128 * 4)

        // Drums: a learned waveform correction from the latest 256 samples, gated by the global state.
        if let enc = w.waveEncode, let gateWeights = w.waveGates, let gb = w.waveGatesBias, let dec = w.waveDecode {
            let k = g.basis
            basis.update(repeating: 0, count: k)
            gemv(enc, rows: k, cols: 256, latest, into: basis)
            var count = Int32(k)
            vvtanhf(basis, basis, &count)
            memcpy(gates, gb, k * 4)
            gemv(gateWeights, rows: k, cols: gw, shared, into: gates)
            sigmoid(gates, k)
            vDSP_vmul(basis, 1, gates, 1, basis, 1, vDSP_Length(k))
            decoded.update(repeating: 0, count: 256)
            gemv(dec, rows: 256, cols: k, basis, into: decoded)
            vDSP_vmul(decoded, 1, hann256, 1, decoded, 1, 256)
            vDSP_vadd(out, 1, decoded, 1, out, 1, 128)
            vDSP_vadd(out, 1, waveTail, 1, out, 1, 128)
            memcpy(waveTail, decoded + 128, 128 * 4)
        }
    }

    /// PyTorch's GRU, one step for `rows` independent rows of `width`: `x` is the input and `h`
    /// the memory, updated in place. Gates in PyTorch's order: reset, update, new.
    private func gru(_ x: Floats, _ h: Floats, rows: Int, width: Int, _ wIH: Floats, _ wHH: Floats, _ bIH: Floats, _ bHH: Floats) {
        let g3 = 3 * width
        for r in 0..<rows { memcpy(gi + r * g3, bIH, g3 * 4); memcpy(gh + r * g3, bHH, g3 * 4) }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(g3), Int32(width), 1, x, Int32(width), wIH, Int32(width), 1, gi, Int32(g3))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(g3), Int32(width), 1, h, Int32(width), wHH, Int32(width), 1, gh, Int32(g3))
        let n = vDSP_Length(width)
        for r in 0..<rows {
            let i = gi + r * g3, hh = gh + r * g3, hr = h + r * width
            // r and z: σ(i + h), into i.
            vDSP_vadd(i, 1, hh, 1, i, 1, vDSP_Length(2 * width))
            sigmoid(i, 2 * width)
            // n = tanh(i_n + r·h_n), into i_n.
            vDSP_vma(i, 1, hh + 2 * width, 1, i + 2 * width, 1, i + 2 * width, 1, n)
            var count = Int32(width)
            vvtanhf(i + 2 * width, i + 2 * width, &count)
            // h = n + z·(h − n).
            vDSP_vsub(i + 2 * width, 1, hr, 1, hr, 1, n)
            vDSP_vma(i + width, 1, hr, 1, i + 2 * width, 1, hr, 1, n)
        }
    }
}

/// y += W·x, W `rows` × `cols` row-major.
private func gemv(_ w: UnsafePointer<Float>, rows: Int, cols: Int, _ x: UnsafePointer<Float>, into y: Floats) {
    cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(cols), 1, w, Int32(cols), x, 1, 1, y, 1)
}

/// σ(v) = ½·tanh(½v) + ½, in place.
private func sigmoid(_ x: Floats, _ n: Int) {
    var half: Float = 0.5, count = Int32(n)
    vDSP_vsmul(x, 1, &half, x, 1, vDSP_Length(n))
    vvtanhf(x, x, &count)
    vDSP_vsmsa(x, 1, &half, &half, x, 1, vDSP_Length(n))
}

/// x·σ(x), in place. Uses a stack buffer: n ≤ 2048.
private func silu(_ x: Floats, _ n: Int) {
    withUnsafeTemporaryAllocation(of: Float.self, capacity: n) { s in
        let p = s.baseAddress!
        memcpy(p, x, n * 4)
        sigmoid(p, n)
        vDSP_vmul(x, 1, p, 1, x, 1, vDSP_Length(n))
    }
}

/// x / √(mean x² + 1e-6) · weight, in place.
private func rmsNorm(_ x: Floats, _ n: Int, _ weight: UnsafePointer<Float>) {
    var ms: Float = 0
    vDSP_measqv(x, 1, &ms, vDSP_Length(n))
    var inv = 1 / (ms + 1e-6).squareRoot()
    vDSP_vsmul(x, 1, &inv, x, 1, vDSP_Length(n))
    vDSP_vmul(x, 1, weight, 1, x, 1, vDSP_Length(n))
}
