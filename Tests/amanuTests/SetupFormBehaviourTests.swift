import AppKit
import Foundation
import Testing

@testable import amanu

/// What the setup form does when it is used, rather than how it is laid out:
/// clicks that have to write something, work that has to survive the window
/// closing, and things it must refuse to do in the middle of a meeting.
@Suite(.serialized)
@MainActor
struct SetupFormBehaviourTests {
    /// A form whose transcription settings live in memory and say "parakeet,
    /// on this Mac", so the local model is the thing it is waiting for.
    private static func localForm() -> SetupForm {
        let form = SetupForm()
        form.storedTranscription = {
            TranscriptionChoice.read(
                engine: "parakeet", cloudProvider: "assemblyai", enabled: true,
                localModels: Platform.supportsLocalModels, localEngine: "parakeet")
        }
        form.write = { _, _ in }
        form.refresh()
        return form
    }

    /// Closing the window stopped the bar's timer and, with it, the form's
    /// only record that a download was running — so opening it again offered
    /// the download a second time, into the same cache, beside the first.
    @Test(
        "A parakeet download outlives the window closing, and reopening does not start another",
        .enabled(if: Platform.supportsLocalModels))
    func parakeetDownloadSurvivesClosing() async throws {
        let form = Self.localForm()
        let gate = Gate()
        var fetches = 0
        form.parakeetIsHere = { false }
        form.fetchParakeet = {
            fetches += 1
            await gate.wait()
        }
        form.refresh()

        // The card's own button rather than the wizard's: on a Mac where the
        // test runner has never been asked for the microphone, the wizard's
        // next step is that prompt, not the download.
        let download = try #require(Self.button("transcription.download.parakeet", in: form))
        download.performClick(nil)
        #expect(form.isDownloading)
        await Task.yield()
        #expect(fetches == 1)

        form.stop()
        #expect(form.isDownloading, "putting the window away forgot the download")
        form.reload()
        #expect(form.progress.machine.localModelDownloading)
        #expect(download.isHidden, "the download was offered again while it was running")
        download.performClick(nil)
        await Task.yield()
        #expect(fetches == 1, "a second fetch started beside the first")

        gate.open()
        for _ in 0..<50 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(fetches == 1)
        form.stop()
    }

    /// The rule was written down on `isRecording` and kept only by the login
    /// item: the system-audio test opened a second tap during a meeting and
    /// played a tone the far end could hear.
    @Test("The system-audio test is refused during a recording, and says why",
          .freshHome)
    func noToneDuringARecording() async throws {
        let form = SetupForm()
        defer { form.stop() }
        var tones = 0
        form.playTestTone = { tones += 1; return .heard }
        var recording = true
        form.isRecording = { recording }
        let row = try #require(Self.view("access.system-audio", in: form) as? AccessRow)

        row.onAct?()
        for _ in 0..<5 { await Task.yield() }
        #expect(tones == 0, "a tone was played into a meeting")
        let words = Self.labels(in: row).joined(separator: " ")
        #expect(words.contains("not while a recording is running"))

        recording = false
        row.onAct?()
        for _ in 0..<5 where tones == 0 { await Task.yield() }
        #expect(tones == 1)
    }
}

extension SetupFormBehaviourTests {
    fileprivate static func button(_ id: String, in form: SetupForm) -> NSButton? {
        view(id, in: form) as? NSButton
    }

    fileprivate static func view(_ id: String, in form: SetupForm) -> NSView? {
        var pending: [NSView] = [form.view]
        while let view = pending.popLast() {
            if view.identifier?.rawValue == id { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The words on screen under a view, hidden ones left out.
    fileprivate static func labels(in root: NSView) -> [String] {
        var found: [String] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let label = view as? NSTextField, !label.isHidden { found.append(label.stringValue) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// Something a test can hold a fake download on until it lets go.
@MainActor
final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
