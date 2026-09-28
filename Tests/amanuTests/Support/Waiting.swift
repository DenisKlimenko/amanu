import Foundation

/// A door a test holds shut: whatever awaits `pass()` waits until the test
/// calls `open()`. For making "still in flight" a fact rather than a delay
/// somebody hoped was long enough.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let released = waiting
        waiting = []
        lock.unlock()
        for continuation in released { continuation.resume() }
    }
}

/// Something that happened, or has not yet, readable from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
