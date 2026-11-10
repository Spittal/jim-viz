import AVFoundation
import Foundation

/// Streams mono audio from one rate to another with AVAudioConverter.
final class Resampler {
    let rate: Double
    let outRate: Double
    /// How far each output sample lags the input sample it stands for, in seconds. Measured once
    /// per pair of rates with an impulse.
    let latency: Double
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    private static let capacity = 16384

    init(from rate: Double, to outRate: Double) {
        self.rate = rate
        self.outRate = outRate
        let inFormat = Self.format(rate), outFormat = Self.format(outRate)
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(Self.capacity))!
        let outCap = Int((Double(Self.capacity) * outRate / rate).rounded(.up)) + 256
        output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outCap))!
        latency = Self.measureLatency(from: rate, to: outRate)
    }

    private static func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    func process(_ samples: UnsafeBufferPointer<Float>, _ emit: (UnsafeBufferPointer<Float>) -> Void) {
        var start = 0
        while start < samples.count {
            let n = min(Self.capacity, samples.count - start)
            memcpy(input.floatChannelData![0], samples.baseAddress! + start, n * 4)
            input.frameLength = AVAudioFrameCount(n)
            start += n
            var fed = false
            while true {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if fed { state.pointee = .noDataNow; return nil }
                    fed = true
                    state.pointee = .haveData
                    return self.input
                }
                if output.frameLength > 0 {
                    emit(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                }
                if status != .haveData { break }
            }
        }
    }

    private static var latencies: [SIMD2<Double>: Double] = [:]
    private static let latencyLock = NSLock()

    /// Feeds an impulse through a fresh converter and finds where it comes out.
    private static func measureLatency(from rate: Double, to outRate: Double) -> Double {
        latencyLock.lock(); defer { latencyLock.unlock() }
        let key = SIMD2(rate, outRate)
        if let l = latencies[key] { return l }
        let inFormat = format(rate), outFormat = format(outRate)
        let conv = AVAudioConverter(from: inFormat, to: outFormat)!
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        let n = Int(rate / 5), at = n / 4
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n))!
        inBuf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { inBuf.floatChannelData![0][i] = i == at ? 1 : 0 }
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n))!
        var fed = false, error: NSError?
        _ = conv.convert(to: outBuf, error: &error) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return inBuf
        }
        let out = UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
        let peak = out.indices.max { abs(out[$0]) < abs(out[$1]) } ?? 0
        let l = Double(peak) / outRate - Double(at) / rate
        latencies[key] = l
        return l
    }
}
