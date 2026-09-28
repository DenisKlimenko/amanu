import Foundation
import Testing

@testable import amanu

/// The wizard's three answers — what is owed, what the button does, what it
/// says — from a machine described in a line, with nothing granted, revoked
/// or downloaded to get there.
struct SetupProgressTests {
    private typealias Machine = SetupProgress.Machine

    @Test("A finished machine owes nothing, and the button says Done")
    func finished() {
        let progress = SetupProgress(Machine())
        #expect(progress.outstanding.isEmpty)
        #expect(progress.next == nil)
        #expect(progress.nextTitle == "Done")
        #expect(progress.sentence == "Everything amanu needs is granted.")
    }

    @Test("Grants come in the order macOS can ask for them")
    func grantOrder() {
        var machine = Machine(
            loginItem: .notRegistered, microphone: .notAsked, systemAudio: nil)
        #expect(SetupProgress(machine).next == .startAtLogin)
        #expect(SetupProgress(machine).nextTitle == "Start at login")
        #expect(SetupProgress(machine).outstanding == [.startAtLogin, .microphone, .systemAudio])

        machine.loginItem = .needsApproval
        #expect(SetupProgress(machine).nextTitle == "Open Login Items")

        machine.loginItem = .enabled
        #expect(SetupProgress(machine).next == .askMicrophone)
        #expect(SetupProgress(machine).nextTitle == "Allow microphone")

        machine.microphone = .granted
        #expect(SetupProgress(machine).next == .testSystemAudio)

        // A denied microphone is owed but not asked for again from here:
        // macOS will not show the prompt twice, and the row sends the person
        // to System Settings instead.
        machine.microphone = .denied
        #expect(SetupProgress(machine).outstanding.contains(.microphone))
        #expect(SetupProgress(machine).next == .testSystemAudio)
    }

    @Test("A bare build is not asked to start at login")
    func bareBuild() {
        let progress = SetupProgress(Machine(loginItem: .unavailable))
        #expect(progress.outstanding.isEmpty)
        #expect(progress.next == nil)
    }

    /// The footer said parakeet was missing whatever engine was chosen.
    @Test("The missing local model is named for the engine that is actually chosen")
    func missingModelIsNamed() {
        for (engine, name) in [("parakeet", "parakeet"), ("whisper", "Whisper"), ("gigaam", "GigaAM")] {
            let progress = SetupProgress(Machine(missingLocalModel: engine))
            #expect(progress.outstanding == [.localModel(engine)])
            #expect(progress.sentence == "One thing left: \(name)")
            #expect(progress.next == .downloadLocalModel)
            #expect(progress.nextTitle == "Download local model")
        }
    }

    @Test("A download that is running is not offered again")
    func runningDownloadIsNotOffered() {
        let local = SetupProgress(Machine(missingLocalModel: "whisper", localModelDownloading: true))
        #expect(local.next == nil)
        #expect(local.isDownloading)
        #expect(local.nextTitle == "Downloading local model…")
        #expect(local.outstanding == [.localModel("whisper")])

        let live = SetupProgress(Machine(liveModelWanted: true, liveModelDownloading: true))
        #expect(live.next == nil)
        #expect(live.nextTitle == "Downloading live model…")

        let both = SetupProgress(Machine(
            missingLocalModel: "parakeet", liveModelWanted: true))
        #expect(both.next == .downloadLocalModel)
        #expect(both.outstanding == [.parakeet, .liveModel])
    }

    @Test("A live model nobody asked for is not owed")
    func unwantedLiveModel() {
        #expect(SetupProgress(Machine(liveModelWanted: false, liveModelReady: false))
            .outstanding.isEmpty)
        let wanted = SetupProgress(Machine(liveModelWanted: true))
        #expect(wanted.outstanding == [.liveModel])
        #expect(wanted.next == .downloadLiveModel)
        #expect(wanted.nextTitle == "Download live model")
    }

    @Test("A missing summary tool is owed, and nothing the button can fetch")
    func summaryTool() {
        let progress = SetupProgress(Machine(summaryToolMissing: true))
        #expect(progress.outstanding == [.summaryTool])
        #expect(progress.next == nil)
        #expect(progress.nextTitle == "Done")
    }
}
