import Foundation
import Testing

@testable import amanu

/// The one window amanu shows before it has any, and the event that says a
/// setup was finished.
struct StartupAlertTests {
    private static func unwritableRoot() throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-startup-\(UUID().uuidString)")
        // A file where the folder should be: the folder can never be made.
        try Data("not a folder".utf8).write(to: base)
        return (base, base.appendingPathComponent("Recordings"))
    }

    @Test("A folder that cannot be made is explained in the window's language", .speaking(.russian))
    func refusalIsInRussian() throws {
        let (base, root) = try Self.unwritableRoot()
        defer { try? FileManager.default.removeItem(at: base) }

        let check = DoctorReport.checkRecordingsRoot(root)
        let body = StartupAlert.body(for: [check])

        #expect(StartupAlert.title == "Amanu не удалось запуститься")
        #expect(body.contains("Не удаётся создать папку записей"))
        #expect(body.contains(root.path))
        #expect(!body.contains("can't create"), "the doctor's English leaked into the window")
    }

    @Test("The doctor's own report stays English whatever the window speaks", .speaking(.russian))
    func doctorStaysEnglish() throws {
        let (base, root) = try Self.unwritableRoot()
        defer { try? FileManager.default.removeItem(at: base) }

        guard case .fail(let why) = DoctorReport.checkRecordingsRoot(root).status else {
            Issue.record("an uncreatable folder passed the check")
            return
        }
        #expect(why.hasPrefix("can't create"))
    }

    @Test("A failure with no sentence of its own still says what the report said")
    func fallbackIsTheReport() {
        let check = Check(name: "something", status: .fail("broke"), remediation: "fix it")
        #expect(StartupAlert.body(for: [check]) == "something: broke\nfix it")
        let passing = Check(name: "fine", status: .ok, remediation: nil)
        #expect(StartupAlert.body(for: [passing]).isEmpty)
    }

    /// Later and the close button both mark setup done, on every way out,
    /// and each one reported another completed setup.
    @Test("Setup is completed once, however many times the window is closed afterwards")
    func completedOnce() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-setup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: state) }

        #expect(SetupState.markCompleted(at: state))
        #expect(!SetupState.markCompleted(at: state))
        #expect(!SetupState.isPending(at: state))

        SetupState.reset(at: state)
        #expect(SetupState.markCompleted(at: state), "a setup asked for again is a new one")
    }
}
