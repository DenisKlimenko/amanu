import Foundation
import Testing
@testable import amanu

struct OfflineEchoTests {
    private final class DelayedBackend: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        private var pending = [Float](repeating: 0, count: 256)

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            let output = pending
            pending = microphone.map { $0 * 0.5 }
            return output
        }
    }

    /// Simulates a perfect echo suppressor with LocalVQE's one-hop latency.
    /// Any raw samples in its output therefore came from Swift's passthrough
    /// selection rather than from the backend.
    private final class DelayedSilenceBackend: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            [Float](repeating: 0, count: hopSize)
        }
    }

    // Independent deterministic signals: a delayed room echo and local speech.
    // Returning the input, swapping channels, or suppressing both voices fails.
    private func signal(seed: UInt64, count: Int) -> [Float] {
        var state = seed
        var low: Float = 0
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1
            let noise = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
            low = 0.7 * low + 0.3 * noise
            return low * 0.6
        }
    }

    @Test("The first delayed hop is discarded and flushing retains the final microphone hop")
    func compensatesStreamingLatency() throws {
        let canceller = try EchoCanceller(backend: DelayedBackend())
        let first = [Float](repeating: 0.4, count: 256)
        let second = [Float](repeating: 0.8, count: 256)
        let reference = [Float](repeating: 0.2, count: 256)

        #expect(try canceller.process(microphone: first, reference: reference) == nil)
        #expect(try canceller.process(microphone: second, reference: reference) == first.map { $0 * 0.5 })
        #expect(try canceller.finish() == second.map { $0 * 0.5 })
        #expect(try canceller.finish() == nil)
    }

    @Test("Playback reference absent from stream start preserves microphone samples exactly")
    func noReference() throws {
        let canceller = try EchoCanceller(backend: DelayedBackend())
        let local = signal(seed: 52, count: 256)
        let following = signal(seed: 53, count: 256)
        let silence = [Float](repeating: 0, count: 256)

        #expect(try canceller.process(
            microphone: local, reference: silence) == nil)
        #expect(try canceller.process(
            microphone: following, reference: silence) == local)
        #expect(try canceller.finish() == following)
    }

    @Test("Delayed echo stays suppressed for one second after reference stops, then quiet local speech is exact")
    func referenceHangover() throws {
        let canceller = try EchoCanceller(backend: DelayedSilenceBackend())
        let frame = EchoCanceller.frameSize
        let activeReference = [Float](repeating: 0, count: frame - 1) + [0.2]
        let silentReference = [Float](repeating: 0, count: frame)
        var output: [Float] = []

        #expect(try canceller.process(
            microphone: .init(repeating: 0, count: frame),
            reference: activeReference) == nil)

        // 13 hops approximate a 200 ms delayed acoustic tail. Returning any
        // raw microphone samples here reintroduces the echo the backend removed.
        for hop in 0..<62 {
            let microphone = [Float](
                repeating: hop < 13 ? 0.8 : 0,
                count: frame)
            output += try canceller.process(
                microphone: microphone,
                reference: silentReference) ?? []
        }

        // The 63rd silent hop crosses exactly 16,000 samples since the final
        // active reference sample. Its first half remains inside hangover;
        // its second half is quiet near-end speech that must be bit-exact.
        let quietLocal = [Float](repeating: 0.03, count: frame)
        output += try canceller.process(
            microphone: quietLocal,
            reference: silentReference) ?? []
        output += try canceller.finish() ?? []

        #expect(output.count == 64 * frame)
        #expect(output[frame..<(14 * frame)].allSatisfy { $0 == 0 })
        let final = Array(output.suffix(frame))
        #expect(final.prefix(128).allSatisfy { $0 == 0 })
        #expect(Array(final.suffix(128)) == Array(quietLocal.suffix(128)))
    }

    @Test(
        "LocalVQE suppresses delayed playback while retaining simultaneous local speech",
        .enabled(if: LocalVQEGate.runs)
    )
    func separatesDoubleTalk() throws {
        let n = 20 * 16_000
        let far = signal(seed: 10, count: n)
        let local = signal(seed: 71, count: n)
        var mic = [Float](repeating: 0, count: n)
        for i in 900..<n {
            mic[i] = 0.65 * far[i - 800] + 0.2 * far[i - 900]
            if i >= 8 * 16_000 { mic[i] += local[i] }
        }
        let canceller = try EchoCanceller()
        var cleaned: [Float] = []
        for i in stride(from: 0, to: n, by: 256) {
            if let frame = try canceller.process(
                microphone: Array(mic[i..<i+256]),
                reference: Array(far[i..<i+256])) {
                cleaned += frame
            }
        }
        cleaned += try canceller.finish() ?? []
        func energy(_ x: [Float], _ range: Range<Int>) -> Double {
            range.reduce(0) { $0 + Double(x[$1] * x[$1]) }
        }
        let echoOnly = 4*16_000..<7*16_000
        #expect(energy(cleaned, echoOnly) < energy(mic, echoOnly) * 0.063)
        let speech = 12*16_000..<19*16_000
        let error = zip(cleaned, local).map { $0 - $1 }
        #expect(energy(error, speech) < energy(local, speech) * 0.15)
        #expect(energy(cleaned, speech) > energy(local, speech) * 0.7)
    }

}
