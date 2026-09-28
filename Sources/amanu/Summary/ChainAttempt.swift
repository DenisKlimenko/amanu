import Foundation

/// One pass down the backend chain that nothing answered, and what it costs
/// the session: another try later, or none.
///
/// Naming and summarizing both end this way and must end it alike. A pass is
/// deferred when some backend failed in a way that passes, so a meeting
/// summarized on a plane still gets its summary that evening. But a deferral
/// is also a promise to send the whole transcript down the chain again, at
/// the next launch and the next change of network, and a promise with no end
/// to it is a meeting re-sent for ever — which is what an unreachable Ollama
/// at the end of every `auto` chain made of every other failure. So the
/// deferrals that handed the meeting to somebody are counted, and after
/// `maxDeferrals` of them the pass gives up the way a permanent failure does:
/// until the settings, keys or backends change.
///
/// A deferral in which nothing was reached at all is not counted. Nothing
/// left the Mac, nobody was paid, and that is the plane.
struct ChainAttempt {
    /// How many times a pass may be deferred after reaching a backend. The
    /// transcription queue allows three failures; a summary gets a few more,
    /// because the commonest reason for this one — a spent allowance — does
    /// come back.
    static let maxDeferrals = 5

    private(set) var anyTransient = false
    /// Whether any backend got the request — answered it, badly or not at
    /// all, but was reached.
    private(set) var anyReached = false

    mutating func note(_ error: Error, from backend: LLMBackend) {
        if backend.failureIsTransient(error) { anyTransient = true }
        if !LLMError.isUnreachable(error) { anyReached = true }
    }

    enum Verdict: Equatable {
        /// Come back later; `deferrals` is the count to record, nil when this
        /// one was not counted and the count stands.
        case deferred(deferrals: Int?)
        /// Give up until the configuration changes.
        case gaveUp(afterDeferrals: Int?)
    }

    /// What to record, given how many counted deferrals the session has had.
    func verdict(after deferrals: Int) -> Verdict {
        guard anyTransient else { return .gaveUp(afterDeferrals: nil) }
        guard anyReached else { return .deferred(deferrals: nil) }
        let counted = deferrals + 1
        return counted >= Self.maxDeferrals
            ? .gaveUp(afterDeferrals: counted)
            : .deferred(deferrals: counted)
    }

    /// The fields to write into meta.json for a verdict: the status, the
    /// fingerprint a `failed` is offered again under, and the count.
    static func fields(
        for verdict: Verdict,
        previous: Int,
        statusKey: String,
        fingerprintKey: String,
        countKey: String,
        fingerprint: @autoclosure () -> String?
    ) -> [String: Any?] {
        switch verdict {
        case .deferred(let counted):
            return [
                statusKey: SessionState.deferred,
                fingerprintKey: nil,
                countKey: counted ?? (previous > 0 ? previous : nil),
            ]
        case .gaveUp:
            // The count goes with the give-up: a changed configuration is a
            // new question, and gets the whole allowance again.
            return [
                statusKey: SessionState.failed,
                fingerprintKey: fingerprint(),
                countKey: nil,
            ]
        }
    }
}
