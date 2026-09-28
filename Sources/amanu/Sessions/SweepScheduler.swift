import Foundation

/// When the running app sweeps the recordings folder: after the queue has
/// drained, and never twice at once.
///
/// Four things ask for a sweep — the launch, the network coming back, the
/// recordings folder changing and a broken config reading again — and two of
/// them arrive in the same turn whenever a fixed config also names a new
/// folder. Each used to start a sweep of its own straight after asking the
/// queue to resume, so two sweeps and a drain walked the same folders at once,
/// each finding the others' claims and saying so in the session logs.
///
/// A request made while a sweep waits for the drain is the same sweep. One
/// made while a sweep is already walking the folder is owed one more pass,
/// since the thing that prompted it — a new folder, a model back — may have
/// come too late for the pass under way.
@MainActor
final class SweepScheduler {
    private enum State {
        case idle
        case waiting
        case sweeping(again: Bool)
    }

    private var state = State.idle
    private let waitForQueue: () async -> Void
    private let sweep: () async -> Void

    init(waitForQueue: @escaping () async -> Void, sweep: @escaping () async -> Void) {
        self.waitForQueue = waitForQueue
        self.sweep = sweep
    }

    /// Whether a sweep is waiting or running.
    var isBusy: Bool {
        if case .idle = state { return false }
        return true
    }

    func request() {
        switch state {
        case .waiting, .sweeping(again: true):
            return
        case .sweeping(again: false):
            state = .sweeping(again: true)
            return
        case .idle:
            state = .waiting
            Task { await self.run() }
        }
    }

    private func run() async {
        while true {
            await waitForQueue()
            state = .sweeping(again: false)
            await sweep()
            guard case .sweeping(again: true) = state else { break }
            state = .waiting
        }
        state = .idle
    }
}
