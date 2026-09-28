import Foundation

/// Whether ⌘Q may go straight through, asked without AppKit in the room.
///
/// The rule is the same one `UpdateGate` holds for Sparkle — a meeting outranks
/// whatever else the program was asked to do — and it lives in its own type for
/// the same reason: a modal panel cannot be tested, and the question it asks
/// can be.
struct QuitGate {
    enum Decision: Equatable {
        case quitNow
        /// Ask first, and say how long the recording has been running: the
        /// number is what makes the choice an informed one.
        case ask(elapsed: TimeInterval)
    }

    private let recordingElapsed: () -> TimeInterval?

    init(recordingElapsed: @escaping () -> TimeInterval? = { nil }) {
        self.recordingElapsed = recordingElapsed
    }

    func decide() -> Decision {
        guard let elapsed = recordingElapsed() else { return .quitNow }
        return .ask(elapsed: elapsed)
    }
}
