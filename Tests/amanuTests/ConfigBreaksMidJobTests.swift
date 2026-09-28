import Foundation
import Testing

@testable import amanu

/// A config file that breaks while amanu is already running on it.
///
/// Readability used to be checked once, where a job began, and the file was
/// then read lazily for the rest of it — minutes later, after a transcription
/// or a naming pass — when every getter fell back to its default. A stray
/// comma saved in that window deleted the audio of somebody who keeps it,
/// summarized an Ollama user's meeting in the cloud, marked their on_stop hook
/// as fired without running it, moved the recordings folder to ~/Recordings
/// and switched auto-record on. The getters now answer with what the file said
/// last, and whatever sends a meeting anywhere waits for the file.
@Suite("A config file that breaks mid-job")
struct ConfigBreaksMidJobTests {
    static let broken = #"{ "keep_audio": true, "summary": { "backend": "ollama" "#

    @Test("Every setting is answered from the file as it last read", .freshHome)
    func gettersKeepTheLastReading() throws {
        try Home.current.writeConfig([
            "keep_audio": true,
            "recordings_dir": "~/Meetings",
            "auto_record": ["enabled": false],
            "summary": ["backend": "ollama"],
        ])
        #expect(Config.keepAudio())
        try Home.current.writeConfig(text: Self.broken)

        #expect(Config.unreadableReason != nil, "the problem is still the problem")
        #expect(!Config.settingsUnknown)
        #expect(Config.keepAudio())
        #expect(!Config.autoRecord().enabled)
        #expect(Config.summary().backend == "ollama")
        #expect(Config.resolveRoot(cliOverride: nil).standardizedFileURL
            == Home.current.url.appendingPathComponent("Meetings", isDirectory: true)
                .standardizedFileURL)
        #expect(!Config.update(path: ["keep_audio"], value: false), "writes are still refused")
        #expect(Home.current.configText == Self.broken)
    }

    /// Nothing to remember, so the defaults stand in — except where a default
    /// would do something the person may well have turned off.
    @Test("A process that never read the file takes auto-record to be off",
          .freshHome(config: broken))
    func nothingRememberedMeansAutoRecordOff() {
        #expect(Config.settingsUnknown)
        #expect(!Config.autoRecord().enabled)
        #expect(Config.defaultFlag(.autoRecordEnabled), "the default this overrides is on")
    }

    // MARK: - the audio

    @Test("Audio kept by the config survives the file breaking during transcription",
          .freshHome(config: #"{"keep_audio": true, "offline_echo_cancellation": false}"#))
    func settleKeepsTheAudio() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28 10-00")
        let home = Home.current
        let engine = FakeEngine("parakeet", answer: { audio, call in
            if call == 1 { try home.writeConfig(text: Self.broken) }
            return try FakeEngine.speech(audio, call)
        })

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(SessionState.value(dir, "audio_discarded") == nil,
                "keep_audio was on when the file last read, and the audio went")
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("audio.m4a").path))
    }

    // MARK: - the meeting's words

    @Test("A summary owed when the file breaks waits for it, and goes nowhere meanwhile")
    func summaryWaitsForTheFile() async throws {
        let cloud = FakeModel.working("claude-cli")
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "ollama"]])
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Naming follows the summary to Ollama, and the file breaks while it
        // is being asked.
        let breaking = FakeModel("ollama") { _, system, _ in
            try home.writeConfig(text: Self.broken)
            return system.contains("identifying who spoke")
                ? SessionFixture.namesThemA : "## Summary\nfrom ollama"
        }
        let models = [cloud.backend, breaking.backend]
        let scoped = Home(
            url: home.url, environment: [:], discoversTools: false,
            languageModels: { LLMBackend.chain(preference: $0, from: models) })

        try await Home.$scoped.withValue(scoped) {
            await PostProcessor.finish(dir, policy: .init(names: true, summary: true))

            #expect(cloud.callCount == 0, "the meeting went to a backend nobody chose")
            #expect(breaking.callCount == 1, "only the naming pass should have been asked")
            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("summary.md").path))
            #expect(SessionState.value(dir, SessionState.Key.summaryStatus) == nil,
                    "a summary held for the file was recorded as an outcome")

            try home.writeConfig(["summary": ["backend": "ollama"]])
            #expect(PostProcessor.outstanding(dir, policy: .init(names: true, summary: true))
                .summary, "once the file reads, the summary is still owed")
        }
    }

    // MARK: - the hook

    @Test("The hook is neither run nor marked while the file is broken, and runs once it is fixed",
          .freshHome)
    func hookWaitsForTheFile() throws {
        let dir = try TestAudio.rawSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = "true"
        try Home.current.writeConfig(["on_stop": command])
        StopHook.owe(dir)
        try Home.current.writeConfig(text: Self.broken)

        #expect(!StopHook.fireIfOwed(dir))
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.owed,
                "the debt was settled while the command could not be read")

        try Home.current.writeConfig(["on_stop": command])
        #expect(StopHook.fireIfOwed(dir))
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.fired)
    }

    /// `amanu process --again` cleared the transcript, the names and the
    /// summary and was only then refused by the transcription it had cleared
    /// them for; without `--again` it marked the hook fired and printed
    /// "Nothing to do".
    @Test("amanu process refuses before it clears or finishes anything",
          .freshHome(config: broken))
    func processRefusesFirst() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(SessionInventory.item(for: dir))

        for again in [false, true] {
            guard case .refuse(let why) = PostProcessor.plan(for: item, again: again),
                  case .configUnreadable = why
            else {
                Issue.record("again: \(again) was not refused for the config")
                continue
            }
            #expect(why.description.contains("config.json can't be read"))
            #expect(why.described.contains("config.json"))
        }
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
    }

    // MARK: - the running app

    @Test("A broken save does not move the recordings folder or flip the icons", .freshHome)
    @MainActor
    func applierIgnoresABrokenSave() throws {
        try Home.current.writeConfig(["recordings_dir": "~/Meetings", "dock_icon": false])
        var taken: [SettingsApplier.Change] = []
        var looks = 0
        let applier = SettingsApplier(apply: { taken.append($0) }, always: { looks += 1 })
        defer { withExtendedLifetime(applier) {} }

        try Home.current.writeConfig(text: Self.broken)
        applier.configChanged()

        #expect(taken.isEmpty, "a broken file was taken up as a change: \(taken)")
        #expect(looks == 1, "the problem still has to be shown")
    }

    @Test("A process that never read the file takes up nothing from it either",
          .freshHome(config: broken))
    @MainActor
    func applierWithNothingRemembered() throws {
        var taken: [SettingsApplier.Change] = []
        let applier = SettingsApplier(apply: { taken.append($0) })
        defer { withExtendedLifetime(applier) {} }
        try Home.current.writeConfig(text: #"{ "recordings_dir": "~/Elsewhere" "#)
        applier.configChanged()
        #expect(taken.isEmpty)
    }

    @Test("Auto-record turned off stays off when the file breaks", .freshHome)
    @MainActor
    func autoRecordStaysOff() throws {
        try Home.current.writeConfig(["auto_record": ["enabled": false, "start_delay_seconds": 0]])
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var starts = 0
        let controller = AutoRecordController(
            settings: Config.autoRecord(),
            calendar: nil,
            checkMic: { _ in
                MicActivityMonitor.Result(
                    active: true, names: ["zoom.us"], families: ["us.zoom.xos"],
                    allHolders: ["zoom.us"])
            },
            now: { now })
        controller.currentSession = { nil }
        controller.startRecording = { _, _ in starts += 1; return true }

        try Home.current.writeConfig(text: Self.broken)
        for _ in 0..<12 {
            now.addTimeInterval(5)
            controller.tick()
        }

        #expect(!controller.enabled)
        #expect(starts == 0, "a call was recorded by a switch its owner had turned off")
    }
}
