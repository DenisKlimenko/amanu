import Foundation
import Testing

@testable import amanu

/// A summary given up on must be as hard to miss as a transcript that was.
///
/// From 2026-10-09 to 2026-11-02 ten meetings went without summaries or
/// names: the `claude` CLI's login had lapsed, Codex and Ollama failed behind
/// it, and every session was marked `failed` and left. The menu bar counted
/// only recordings without a transcript, so nothing said so — and once the
/// login was fixed, nothing the fingerprint sees had changed, so nothing
/// tried again either.
@MainActor
struct GivenUpTests {
    private static let lapsed = LLMError.exit(
        1, "Failed to authenticate: OAuth session expired and could not be refreshed")
    private static let both = PostProcessor.Policy(names: true, summary: true)

    /// The incident's chain: a lapsed login, a CLI whose first line of output
    /// is its banner, and an Ollama nobody started.
    private static let broken = [
        FakeModel("claude-cli", failing: lapsed),
        FakeModel("codex-cli", failing: LLMError.exit(1, "OpenAI Codex v0.153.4\nerror: 401")),
        FakeModel("ollama", failing: URLError(.cannotConnectToHost)),
    ]

    /// A recordings root of its own holding one transcribed session, so the
    /// scan sees nothing else in the temporary directory.
    private static func root() throws -> (root: URL, dir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent("2026.10.28-1000", isDirectory: true)
        try FileManager.default.moveItem(at: try SessionFixture.make(), to: dir)
        return (root, dir)
    }

    private static func run<R>(
        _ models: [FakeModel], _ body: () async throws -> R
    ) async throws -> R {
        let home = Home.withModels(models)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["user_name": "Самат"])
        return try await Home.$scoped.withValue(home) { try await body() }
    }

    /// Finish the way the sweep does until there is nothing left to offer.
    private static func giveUp(_ dir: URL) async throws {
        try await run(broken) {
            for _ in 0..<(ChainAttempt.maxDeferrals + 2) {
                guard !PostProcessor.outstanding(dir, policy: both).isEmpty else { return }
                await PostProcessor.finish(dir, policy: both)
            }
        }
    }

    @Test("A give-up records what the first backend that answered said, and the menu shows it")
    func reasonReachesTheMenu() async throws {
        let (root, dir) = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }

        try await Self.giveUp(dir)

        let said = "claude-cli: exited 1: Failed to authenticate: OAuth session expired "
            + "and could not be refreshed"
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.failed)
        #expect(SessionState.value(dir, SessionState.Key.summaryFailedBecause) as? String == said)
        #expect(SessionState.value(dir, SessionState.Key.speakersFailedBecause) as? String == said)

        let givenUp = PostProcessor.givenUp(in: root, policy: Self.both)
        #expect(givenUp.map(\.dir.lastPathComponent) == [dir.lastPathComponent])
        #expect(givenUp.first?.reason == said)

        let line = try #require(AppController.untranscribedLine(
            count: 0, givenUp: givenUp.count, reason: givenUp.first?.reason))
        #expect(line.hasPrefix("⚠︎ no summary or names: 1 — claude-cli: exited 1: Failed"))
        #expect(line.hasSuffix("…"))

        let item = try #require(SessionInventory.item(for: dir, policy: Self.both))
        #expect(item.summary == .failed(said))
        #expect(item.hasGivenUp)
        #expect(!item.isOutstanding)
        #expect(item.summaryLine.contains("\n    summary failed: \(said)"))
    }

    @Test("Finish processing tries a give-up again, and a fixed backend clears the warning")
    func askingRetries() async throws {
        let (root, dir) = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.giveUp(dir)

        // Under the configuration it gave up with, so the fingerprint matches.
        try await Self.run(Self.broken) {
            #expect(PostProcessor.outstanding(dir, policy: Self.both).isEmpty)
            let asked = PostProcessor.outstanding(dir, policy: Self.both, retryingFailed: true)
            #expect(asked == .init(names: true, summary: true))
            let item = try #require(SessionInventory.item(for: dir, policy: Self.both))
            #expect(RecordingsWindow.decision(for: item, policy: Self.both) == .finish)
        }

        // The login is fixed outside amanu: same settings, same fingerprint.
        let work = try await Self.run([FakeModel.working("claude-cli")]) {
            await PostProcessor.finish(dir, policy: Self.both, retryingFailed: true)
        }

        #expect(work == .init(names: true, summary: true))
        #expect(PostProcessor.hasCurrentSummary(dir))
        for key in [
            SessionState.Key.summaryStatus, SessionState.Key.summaryFailedBecause,
            SessionState.Key.speakersStatus, SessionState.Key.speakersFailedBecause,
        ] {
            #expect(SessionState.value(dir, key) == nil, "\(key)")
        }
        #expect(PostProcessor.givenUp(in: root, policy: Self.both).isEmpty)
    }

    @Test("A retry that asks no backend keeps the give-up but not the old reason")
    func retryThatAsksNobody() async throws {
        let (root, dir) = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.giveUp(dir)

        try await Self.run([]) {
            await PostProcessor.finish(dir, policy: Self.both, retryingFailed: true)
        }

        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.failed)
        #expect(SessionState.value(dir, SessionState.Key.summaryFailedBecause) == nil)
        let givenUp = PostProcessor.givenUp(in: root, policy: Self.both)
        #expect(givenUp.count == 1)
        #expect(givenUp.first?.reason == nil)
    }

    @Test("A step that is off now is not a warning")
    func offIsNotGivenUp() async throws {
        let (root, dir) = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.giveUp(dir)

        #expect(PostProcessor.givenUp(
            in: root, policy: .init(names: false, summary: false)).isEmpty)
    }

    @Test("A burst of give-ups gets one banner")
    func oneBannerPerBurst() {
        var throttle = PostProcessor.BannerThrottle()
        let start = Date()
        let answers = [0, 30, 14 * 60, 16 * 60].map {
            throttle.allows(at: start.addingTimeInterval(TimeInterval($0)))
        }
        #expect(answers == [true, false, false, true])
    }

    @Test("Finish processing gets its banner even inside the quiet quarter hour")
    func askedRetryIsAnswered() {
        var throttle = PostProcessor.BannerThrottle()
        let start = Date()
        let answers = [
            throttle.allows(at: start),
            throttle.allows(at: start.addingTimeInterval(60), asked: true),
            // The sweep after the press waits from the press.
            throttle.allows(at: start.addingTimeInterval(15 * 60)),
        ]
        #expect(answers == [true, true, false])
    }

    @Test("The line names both counts, and either alone")
    func line() {
        #expect(AppController.untranscribedLine(count: 0, givenUp: 0, reason: "x") == nil)
        #expect(AppController.untranscribedLine(count: 2) == "⚠︎ not transcribed: 2")
        #expect(AppController.untranscribedLine(count: 0, givenUp: 3)
            == "⚠︎ no summary or names: 3")
        #expect(AppController.untranscribedLine(count: 2, givenUp: 3, reason: "claude-cli: no")
            == "⚠︎ not transcribed: 2 · no summary or names: 3 — claude-cli: no")
    }
}
