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
}

extension SetupFormBehaviourTests {
    fileprivate static func button(_ id: String, in form: SetupForm) -> NSButton? {
        var pending: [NSView] = [form.view]
        while let view = pending.popLast() {
            if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
            pending.append(contentsOf: view.subviews)
        }
        return nil
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
