import Foundation
import os
import Testing

@testable import amanu

/// Native decoding that blocks for minutes must not hold the threads every
/// other task in the process runs on.
struct DedicatedThreadTests {
    @Test("More blocking decodes than cores still leave the cooperative pool free")
    func blockingWorkDoesNotStarveThePool() async throws {
        let blockers = ProcessInfo.processInfo.activeProcessorCount + 2
        let release = OSAllocatedUnfairLock(initialState: false)
        let running = OSAllocatedUnfairLock(initialState: 0)

        let decodes = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<blockers {
                    group.addTask {
                        try await DedicatedThread.run("test") {
                            running.withLock { $0 += 1 }
                            while !release.withLock({ $0 }) { usleep(1_000) }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        while running.withLock({ $0 }) < blockers { try await Task.sleep(for: .milliseconds(5)) }

        // With every decode blocking a pool thread, this would never be
        // scheduled; on threads of their own it runs at once.
        let answered = await Task.detached { 42 }.value
        #expect(answered == 42)

        release.withLock { $0 = true }
        try await decodes.value
    }

    @Test("A result and an error come back to the awaiting task")
    func resultsAndErrorsReturn() async throws {
        struct Boom: Error {}
        #expect(try await DedicatedThread.run("test") { 7 } == 7)
        await #expect(throws: Boom.self) { try await DedicatedThread.run("test") { throw Boom() } }
    }
}
