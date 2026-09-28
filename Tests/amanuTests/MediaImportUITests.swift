import Foundation
import AppKit
import Testing

@testable import amanu

struct MediaImportUITests {
    @Test("Both ordinary windows offer the same visible Import command")
    @MainActor
    func windowEntryPoints() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-import-ui-\(UUID().uuidString)")
        let status = StatusWindow()
        let recordings = RecordingsWindow(root: root)

        for view in [status.view, recordings.view] {
            let button = try #require((view?.allDescendants ?? []).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "choose-media-import" })
            #expect(button.title == "Import…")
            #expect(button.target != nil)
            #expect(button.action != nil)
        }
        withExtendedLifetime((status, recordings)) {}
    }

    @Test("The first import update reveals progress when the status window was hidden")
    @MainActor
    func progressRevealsStatusWindow() {
        _ = NSApplication.shared
        let status = StatusWindow()
        status.hide()
        #expect(!status.isVisible)

        status.updateImport(.init(
            source: URL(fileURLWithPath: "/tmp/interview.mov"),
            index: 1, total: 1, stage: .checking, fraction: nil))

        #expect(status.isVisible)
        status.hide()
        withExtendedLifetime(status) {}
    }

    @Test("Import progress names the file and its place in a multi-file queue")
    func progressCopy() {
        let source = URL(fileURLWithPath: "/tmp/interview.mov")
        let update = MediaImportCoordinator.Update(
            source: source, index: 2, total: 4, stage: .normalizing, fraction: 0.375)

        let copy = MediaImportPresentation.progress(update)
        #expect(copy.label.contains("2 of 4"))
        #expect(copy.label.contains("interview.mov"))
        #expect(copy.fraction == 0.375)
    }

    @Test("Import completion distinguishes successes, duplicates and failures")
    func completionCopy() {
        var result = MediaImportCoordinator.Result()
        result.imported = [.init(source: URL(fileURLWithPath: "/tmp/a.mp3"),
                                 session: URL(fileURLWithPath: "/tmp/session"))]
        result.duplicates = [.init(source: URL(fileURLWithPath: "/tmp/a-copy.mp3"),
                                   existingSession: URL(fileURLWithPath: "/tmp/session"))]
        result.failures = [.init(source: URL(fileURLWithPath: "/tmp/silent.mov"),
                                 message: "no audio")]

        let copy = MediaImportPresentation.finished(result)
        #expect(copy.label.contains("Imported 1"))
        #expect(copy.label.contains("1 already here"))
        #expect(copy.label.contains("1 failed"))
        #expect(copy.label.contains("silent.mov: no audio"))
        #expect(copy.fraction == 1)
    }


}
