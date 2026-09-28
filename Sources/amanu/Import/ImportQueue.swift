import Foundation

/// The files waiting to be imported, and whether a run is working through
/// them — the bookkeeping of the app's import loop, without the loop. Files
/// offered while a batch is in AVFoundation are coalesced into the next
/// batch rather than starting a second normalizer beside the first.
///
/// It was a list and a task handle side by side, and the gap between them
/// lost files. Cancelling emptied the list and cancelled the task, but the
/// task took a moment to wind down; files dropped on a window in that moment
/// saw a task still there, joined the list to wait for it, and were thrown
/// away when the winding-down task emptied the list on its way out. Nothing
/// said so. Here a cancel stops the run and forgets what was waiting at that
/// moment, and anything that arrives afterwards starts a run of its own.
struct ImportQueue {
    private var waiting: [URL] = []
    /// Whether a run is going. Only one ever is: imports are serial.
    private(set) var isRunning = false
    /// The run going now was told to stop.
    private var stopping = false
    /// No run may start again — the app is quitting.
    private var closed = false

    /// Files to import. True when the caller should start a run for them;
    /// false when the run already going will take them, or nothing will.
    mutating func add(_ files: [URL]) -> Bool {
        guard !closed, !files.isEmpty else { return false }
        waiting.append(contentsOf: files)
        guard !isRunning else { return false }
        isRunning = true
        stopping = false
        return true
    }

    /// The next files for the run to import, all of them at once, or nil
    /// when the run should end.
    mutating func nextBatch() -> [URL]? {
        guard isRunning, !stopping, !waiting.isEmpty else { return nil }
        defer { waiting.removeAll(keepingCapacity: true) }
        return waiting
    }

    /// Stop the run and forget what was waiting for it. Files added after
    /// this are a new request, and are kept for a run of their own.
    mutating func cancel() {
        waiting.removeAll(keepingCapacity: true)
        if isRunning { stopping = true }
    }

    /// Cancel for good: nothing starts again.
    mutating func close() {
        cancel()
        closed = true
    }

    /// The run has ended. True when files came in while it was stopping, and
    /// the caller should start another run for them now.
    mutating func runEnded() -> Bool {
        isRunning = false
        stopping = false
        guard !closed, !waiting.isEmpty else { return false }
        isRunning = true
        return true
    }
}
