import Foundation

/// What a failed transcription costs the session it happened to: an attempt,
/// or its place in the queue for good.
enum TranscriptionFailurePolicy {
    /// How many times a session may fail before the queue stops offering it.
    /// The queue lives in the filesystem and is rescanned at every launch, so
    /// without a limit a session that cannot be transcribed is retried for
    /// ever — and with a cloud engine, re-uploaded and re-charged every time.
    static let maxAttempts = 3

    static func hasGivenUp(on dir: URL) -> Bool {
        SessionState.value(dir, SessionState.Key.transcriptionFailed) != nil
    }

    /// Network-shaped failures, the ones a local engine can rescue. A bad key
    /// or a rejected file is not one of them — retrying locally would still be
    /// right, but silently swapping engines for every failure hides real
    /// problems.
    static func looksLikeNetworkTrouble(_ error: Error) -> Bool {
        let urlErrorCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        ]
        if let urlError = error as? URLError { return urlErrorCodes.contains(urlError.code) }
        return "\(error)".contains("offline") || "\(error)".contains("timed out")
    }

    /// Count a failure against the session, and retire it once retrying has
    /// stopped being reasonable — either because the error can't be fixed by
    /// repeating it, or because we've repeated it enough.
    ///
    /// A retired session keeps its audio and gets it compressed: there will
    /// never be a transcript, so holding a gigabyte an hour of PCM against a
    /// future attempt is pure waste. Delete `transcription_failed` from
    /// meta.json to offer it to the queue again.
    static func record(_ error: Error, for dir: URL, engine: TranscriptionEngine?) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }
        let permanent = (error as? TranscriptionFailure)?.isPermanent ?? false
        let attempts =
            (SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int ?? 0) + 1
        let gaveUp = permanent || attempts >= maxAttempts
        let engineName = engine?.name ?? Config.transcriptionEngine()
        let reason: Analytics.Reason = {
            if looksLikeNetworkTrouble(error) { return .noNetwork }
            if permanent { return .refused }
            return Analytics.reason(for: error)
        }()
        Analytics.track(.transcriptFailed, [
            .engine: .text(engineName),
            .model: .text(AnalyticsCatalogue.transcriptionModel(
                engine: engineName, provenance: engine?.model ?? "")),
            .reason: .text(reason.rawValue),
            .outcome: .text((gaveUp
                ? Analytics.Outcome.gaveUp : .deferred).rawValue),
        ])
        var fields: [String: Any?] = [SessionState.Key.transcriptionAttempts: attempts]

        if gaveUp {
            fields[SessionState.Key.transcriptionFailed] = "\(error)"
            SessionState.update(dir, with: fields)
            log(permanent
                ? "giving up: \(error) — retrying cannot change this"
                : "giving up after \(attempts) attempts")
            notifyUser(
                title: localised(
                    "amanu — transcription gave up", "amanu — расшифровка не вышла"),
                body: dir.lastPathComponent + localised(
                    " — audio kept, see transcribe.log",
                    " — звук сохранён, подробности в transcribe.log"),
                opening: dir
            )
            TrackCompressor.compress(sessionDir: dir)
        } else {
            SessionState.update(dir, with: fields)
            notifyUser(
                title: localised(
                    "amanu — transcription failed", "amanu — расшифровка не удалась"),
                body: dir.lastPathComponent + localised(
                    " — see transcribe.log", " — подробности в transcribe.log"),
                opening: dir
            )
        }
    }
}
