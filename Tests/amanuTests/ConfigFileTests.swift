import AppKit
import Foundation
import Testing

@testable import amanu

/// A config file that cannot be parsed.
///
/// It used to read exactly like no file at all: every setting fell back to its
/// default — analytics on, the engine `auto` and so the cloud — and the next
/// switch anybody touched wrote that one key over the whole file. These are the
/// promises that replaced that: the file is never written over, nothing that
/// could send a meeting anywhere runs, analytics is off, every surface says so,
/// and it all comes back when the file does.
@Suite("A config file that cannot be read")
struct ConfigFileTests {
    static let broken = #"{ "analytics": false, "transcription": { "engine": "parakeet" "#

    // MARK: - telling the cases apart

    @Test("No file, an empty file, a good file and a broken one are four answers", .freshHome)
    func theFileIsToldApart() throws {
        guard case .absent = Config.file() else {
            Issue.record("no file read as something else")
            return
        }
        try Home.current.writeConfig(text: "  \n")
        guard case .parsed(let empty) = Config.file(), empty.isEmpty else {
            Issue.record("an empty file is not an empty config")
            return
        }
        try Home.current.writeConfig(["keep_audio": true])
        guard case .parsed(let good) = Config.file(), good["keep_audio"] as? Bool == true else {
            Issue.record("a good file did not parse")
            return
        }
        try Home.current.writeConfig(text: Self.broken)
        guard case .unreadable(let reason) = Config.file() else {
            Issue.record("a broken file parsed")
            return
        }
        #expect(!reason.isEmpty)
        try Home.current.writeConfig(text: "[1, 2]")
        #expect(Config.unreadableReason != nil, "an array is not a config")
    }

    // MARK: - the file is not written over

    @Test("A setting changed while the file is broken is refused, and the file is left as it was",
          .freshHome(config: broken))
    func writesAreRefused() {
        #expect(!Config.update(path: ["keep_audio"], value: true))
        #expect(!Config.update(path: ["auto_record", "enabled"], value: false))
        #expect(Home.current.configText == Self.broken)
    }

    @Test("Once the file is fixed, settings are saved into it again", .freshHome(config: broken))
    func writesResumeWhenFixed() throws {
        try Home.current.writeConfig(["analytics": false])
        #expect(Config.update(path: ["keep_audio"], value: true))
        guard case .parsed(let json) = Config.file() else {
            Issue.record("the fixed file no longer parses")
            return
        }
        #expect(json["analytics"] as? Bool == false, "the write lost what was already there")
        #expect(json["keep_audio"] as? Bool == true)
    }

    // MARK: - nothing leaves the Mac

    @Test("Analytics is off while the file is broken, whatever the default", .freshHome)
    func analyticsIsOff() throws {
        #expect(AnalyticsIdentity.isEnabled(), "no file means the default, which is on")
        try Home.current.writeConfig(text: Self.broken)
        #expect(!AnalyticsIdentity.isEnabled())
        try Home.current.writeConfig(["analytics": true])
        #expect(AnalyticsIdentity.isEnabled())
    }

    /// An engine that notes being asked, which is all this needs to know.
    private actor CountingEngine: TranscriptionEngine {
        nonisolated let name = "counting"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput = .perTrack
        private(set) var calls = 0
        func prepare() async throws { calls += 1 }
        func release() async {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            calls += 1
            return [.init(start: 0, end: 1, text: "words")]
        }
    }

    @Test("A session is held rather than transcribed, and not counted as a failure",
          .freshHome(config: broken))
    func transcriptionIsHeld() async throws {
        let dir = try TestAudio.rawSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = CountingEngine()

        await #expect(throws: Config.Unreadable.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }

        #expect(await engine.calls == 0)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil,
                "a held session was counted towards retiring it")
        #expect(!SessionClaim.isHeld(dir))
        #expect(TranscriptionCoordinator.pendingSessions(in: dir.deletingLastPathComponent())
            .map(\.lastPathComponent).contains(dir.lastPathComponent),
            "a held session must still be pending when the file is fixed")
    }

    @Test("Names and summaries wait too, and no model is asked", .freshHome(config: broken))
    func postProcessingWaits() async throws {
        let dir = try TestAudio.rawSession(postProcessing: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-28T09:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Привет.")]
        ).write(to: dir)

        let asked = Asked()
        let fake = LLMBackend(name: "fake", model: nil) { _, _ in
            asked.note()
            return "summary"
        }
        let home = Home(
            url: Home.current.url, environment: [:], discoversTools: false,
            languageModels: { _ in [fake] })
        let work = await Home.$scoped.withValue(home) {
            await PostProcessor.finish(dir, policy: .init(names: true, summary: true))
        }
        #expect(work.isEmpty)
        #expect(asked.count == 0)
        #expect(await PostProcessor.sweep(root: dir.deletingLastPathComponent()) == 0)
    }

    // MARK: - saying so

    @Test("The doctor warns, and does not fail — recording goes on", .freshHome(config: broken))
    func doctorWarns() {
        let check = DoctorReport.checkConfig()
        guard case .warn(let text) = check.status else {
            Issue.record("a broken config was not a warning: \(check.status)")
            return
        }
        #expect(text.contains("config.json can't be read"))
        #expect(check.remediation?.contains(Config.path.path) == true)
        #expect(DoctorReport.canContinueIntoSetup([check]))
    }

    @Test("A good file gives the doctor nothing to say", .freshHome(config: #"{"keep_audio": true}"#))
    func doctorIsQuietOtherwise() {
        guard case .ok = DoctorReport.checkConfig().status else {
            Issue.record("a good config was reported")
            return
        }
    }

    @Test("The menu and the status window say it in one line", .freshHome(config: broken))
    @MainActor
    func menuAndStatusWindowSaySo() throws {
        let headline = try #require(Config.problems().first?.headline)
        let menuBar = MenuBarController(visible: false)
        #expect(!menuBar.offeredItemTitles.contains { $0.contains(headline) })
        menuBar.updateConfigProblem(headline)
        #expect(menuBar.offeredItemTitles.contains { $0.contains(headline) })
        menuBar.updateConfigProblem(nil)
        #expect(!menuBar.offeredItemTitles.contains { $0.contains(headline) })

        let window = StatusWindow()
        window.updateConfigProblem(headline)
        let shown = (window.view?.allDescendants ?? [])
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
        #expect(shown.contains(headline))
    }

    @Test("The setup and settings windows explain it, once each", .freshHome(config: broken))
    @MainActor
    func windowsExplain() throws {
        let explanation = try #require(Config.problems().first?.explanation)
        func visible(in view: NSView?) -> [String] {
            (view?.allDescendants ?? [])
                .compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor }
                .map(\.stringValue)
        }

        let form = SetupForm()
        defer { form.stop() }
        #expect(visible(in: form.view).filter { $0 == explanation }.count == 1)

        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu settings" })
        #expect(visible(in: panel.contentView).filter { $0 == explanation }.count == 1,
                "the settings window should say it once, under both tabs")
    }

    @Test("Every sentence about the file is said in Russian too")
    func russianToo() {
        let problems: [Config.Problem] = [
            .unreadable(reason: "Unexpected end of file"),
            .unusable(key: "keep_audio", found: #""yes""#, expected: "true or false"),
        ]
        for problem in problems {
            let english = (problem.headline, problem.explanation)
            let russian = InterfaceLanguage.$scoped.withValue(.russian) {
                (problem.headline, problem.explanation)
            }
            #expect(english.0 != russian.0)
            #expect(english.1 != russian.1)
        }
        let unreadable = InterfaceLanguage.$scoped.withValue(.russian) { problems[0].explanation }
        #expect(unreadable.contains("Unexpected end of file"), "the parser's reason is kept")
    }

    // MARK: - coming back

    @Test("An edit from outside is announced once, and a write from inside is not repeated",
          .freshHome(config: broken))
    func diskWatchAnnouncesOutsideEdits() throws {
        // A centre of the test's own: other suites post `didChange` on the
        // default one all the time, and would be counted here.
        let center = NotificationCenter()
        let watch = ConfigWatch.DiskWatch(file: Config.path, every: nil, center: center)
        defer { withExtendedLifetime(watch) {} }
        let posts = Posts()
        let observer = center.addObserver(
            forName: Config.didChange, object: nil, queue: nil) { _ in posts.note() }
        defer { center.removeObserver(observer) }

        watch.check()
        #expect(posts.count == 0, "nothing changed yet")

        try Home.current.writeConfig(["keep_audio": true])
        watch.check()
        #expect(posts.count == 1, "the fix made in an editor went unheard")
        watch.check()
        #expect(posts.count == 1)

        // A write of our own, and the announcement `Config.update` makes of
        // it; the watch must not make a second one.
        #expect(Config.update(path: ["dock_icon"], value: false))
        center.post(name: Config.didChange, object: nil)
        #expect(posts.count == 2)
        watch.check()
        #expect(posts.count == 2, "our own write was announced a second time")
    }
}

/// A count that a closure on any thread can add to.
private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private typealias Asked = Posts
