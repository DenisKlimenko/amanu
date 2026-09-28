import Foundation

/// Blocking work on a thread of its own, awaited without holding a thread of
/// the cooperative pool.
///
/// `whisper_full` and GigaAM's `transcribe_run` block for as long as a chunk
/// takes to decode — minutes for a long meeting on a slow Mac — and the pool
/// has one thread per core. Run there, a transcription held a core's worth of
/// every actor and every task in the process for its whole length, the
/// recording's among them. The work keeps its own cancellation: the native
/// libraries poll an abort callback, and the callers flip it from the task's
/// cancellation handler.
enum DedicatedThread {
    static func run<T: Sendable>(
        _ name: String,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "amanu \(name)"
            thread.qualityOfService = .userInitiated
            // ggml's graph building recurses; the 512 KB a secondary thread
            // gets by default is not what either library was written for.
            thread.stackSize = 8 << 20
            thread.start()
        }
    }
}
