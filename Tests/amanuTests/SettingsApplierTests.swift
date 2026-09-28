import Foundation
import Testing

@testable import amanu

/// The one reader of every setting a running amanu takes up without a
/// restart: whichever window writes one, this is what hears it.
@Suite(.serialized)
@MainActor
struct SettingsApplierTests {
    @Test("Only what moved is taken up, once")
    func changesAreTheDifference() {
        let before = SettingsApplier.Snapshot(
            liveTranscription: false, menuBarIcon: true, dockIcon: true,
            recordingsRoot: URL(fileURLWithPath: "/tmp/Recordings"))
        var after = before
        #expect(SettingsApplier.changes(from: before, to: after).isEmpty)

        after.liveTranscription = true
        after.dockIcon = false
        #expect(SettingsApplier.changes(from: before, to: after)
            == [.liveTranscription(true), .icons])
    }

    /// The setup form's live-transcript switch wrote the setting and nothing
    /// else, so a meeting switched on from there went on without it. Every
    /// switch now only writes; this is what has to hear the write.
    @Test(
        "A write from any window reaches the applier, and a redraw that writes nothing does not",
        .freshHome)
    func aWriteIsTakenUp() {
        var taken: [SettingsApplier.Change] = []
        var looks = 0
        let applier = SettingsApplier(apply: { taken.append($0) }, always: { looks += 1 })
        defer { withExtendedLifetime(applier) {} }

        Config.update(path: ["live_transcription", "enabled"], value: true)
        #expect(taken == (Platform.supportsLocalModels ? [.liveTranscription(true)] : []))

        taken = []
        Config.update(path: ["menu_bar_icon"], value: false)
        #expect(taken == [.icons])

        taken = []
        NotificationCenter.default.post(name: Config.didChange, object: nil)
        #expect(taken.isEmpty, "nothing moved, and something was taken up anyway")
        #expect(looks == 3)
    }

    /// Choosing a folder in Setup wrote `recordings_dir` and changed nothing
    /// until the next launch, silently. The applier is what hears it now.
    @Test("A recordings folder chosen in Setup is taken up as the folder it names", .freshHome)
    func recordingsFolderIsTakenUp() {
        var taken: [SettingsApplier.Change] = []
        let applier = SettingsApplier(apply: { taken.append($0) })
        defer { withExtendedLifetime(applier) {} }

        Config.update(path: ["recordings_dir"], value: "~/Meetings")

        let expected = Home.current.url.appendingPathComponent("Meetings", isDirectory: true)
        #expect(taken == [.recordingsRoot(expected.standardizedFileURL)])
    }
}
