import Foundation
import Testing

@testable import amanu

/// When the running app sweeps the recordings folder: after the queue, and
/// one sweep at a time however many things ask for one.
@MainActor
struct SweepSchedulerTests {
    /// A queue that drains when told to, and a sweep that counts itself and
    /// can be held in the middle.
    @MainActor
    private final class Harness {
        let drained = Gate()
        let sweepStarted = Gate()
        let releaseSweep = Gate()
        var sweeps = 0
        lazy var scheduler = SweepScheduler(
            waitForQueue: { [drained] in await drained.pass() },
            sweep: { [unowned self] in
                sweeps += 1
                sweepStarted.open()
                await releaseSweep.pass()
            })
    }

    /// Let the scheduler's task run, and for as long as it is still busy —
    /// up to a second, which a loaded test run can need.
    private static func settle(_ scheduler: SweepScheduler? = nil) async {
        for _ in 0..<20 { await Task.yield() }
        guard let scheduler else { return }
        for _ in 0..<100 where scheduler.isBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `resumePending` returns once its drain has begun, and the sweep used
    /// to start then, walking the folder beside the session being settled.
    @Test("The sweep waits for the queue to drain")
    func sweepWaitsForTheQueue() async {
        let h = Harness()
        h.releaseSweep.open()
        h.scheduler.request()
        await Self.settle()
        #expect(h.sweeps == 0, "swept while the queue was still draining")

        h.drained.open()
        await h.sweepStarted.pass()
        #expect(h.sweeps == 1)
    }

    /// A fixed config that also names a new folder asked for a sweep twice
    /// in one turn, and got two, walking the folder side by side.
    @Test("Requests made while a sweep waits are that sweep")
    func requestsWhileWaitingCoalesce() async {
        let h = Harness()
        h.releaseSweep.open()
        h.scheduler.request()
        h.scheduler.request()
        h.scheduler.request()
        h.drained.open()
        await h.sweepStarted.pass()
        await Self.settle(h.scheduler)
        #expect(h.sweeps == 1)
        #expect(!h.scheduler.isBusy)
    }

    @Test("A request made while a sweep is walking the folder is owed one more pass")
    func requestDuringASweepRunsOnceMore() async {
        let h = Harness()
        h.drained.open()
        h.scheduler.request()
        await h.sweepStarted.pass()

        h.scheduler.request()
        h.scheduler.request()
        h.releaseSweep.open()
        await Self.settle(h.scheduler)

        #expect(h.sweeps == 2)
        #expect(!h.scheduler.isBusy)
    }
}

@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct QueueIdleTests {
    @Test("Waiting for the queue returns once the drain it started is over")
    func waitUntilIdleWaitsForTheDrain() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28 10-00")
        let engine = FakeEngine("parakeet", answer: { audio, call in
            Thread.sleep(forTimeInterval: 0.05)
            return try FakeEngine.speech(audio, call)
        })
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })

        await coordinator.waitUntilIdle()
        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(!SessionClaim.isHeld(dir))
    }
}
