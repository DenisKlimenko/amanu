import Foundation
import Testing

@testable import amanu

/// The small files in a session folder are amended by several hands at once.
/// Each amendment has to land whatever the others are doing.
struct SessionLockTests {
    @Test("Writers amending different keys of meta.json at once all land")
    func concurrentAmendmentsAllLand() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            _ = SessionState.update(dir, with: ["key\(index)": index])
        }

        let meta = try #require(SessionState.read(dir))
        var missing: [Int] = []
        for key in 0..<64 where (meta["key\(key)"] as? Int) != key { missing.append(key) }
        #expect(missing.isEmpty, "Lost to a concurrent read-modify-write: \(missing)")
        #expect(meta["title"] as? String == "Planning")
    }

    @Test("A meta.json that cannot be written is an error, not a silence")
    func anUnwritableMetaIsReported() throws {
        let dir = try SessionFixture.make()
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        chmod(dir.path, 0o555)
        defer { chmod(dir.path, 0o755) }

        #expect(throws: SessionState.StateError.self) {
            try SessionState.amend(dir, with: [SessionState.Key.summaryStatus: "deferred"])
        }
        #expect(!SessionState.update(dir, with: [SessionState.Key.summaryStatus: "deferred"]))
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) == nil)
    }

    @Test("A session with no meta.json is not given one made of a status alone")
    func aMissingMetaIsNotInvented() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))

        #expect(!SessionState.update(dir, with: [SessionState.Key.summaryStatus: "failed"]))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test("Code holding the lock can call code that takes it again")
    func theLockIsReentrantWithinATask() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let value = SessionLock.withLock(dir) {
            SessionLock.withLock(dir) {
                SessionState.update(dir, with: ["inner": true])
            }
        }
        #expect(value)
        #expect(SessionState.value(dir, "inner") as? Bool == true)
    }

    /// The case the lock was added for. A person names a speaker in the
    /// recordings window during the minutes a naming run waits on its model;
    /// the run then merged its answer into the copy of `speakers.json` it had
    /// read before asking, and the person's name was gone.
    @Test("A name typed by hand while the model is thinking survives its answer")
    func aManualRenameDuringARunIsKept() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel("claude-cli") { _, _, _ in
            PostProcessor.rename("them A", to: "Анна", in: dir)
            return SessionFixture.namesThemA
        }
        let home = Home.withModels([model])
        try home.writeConfig(["user_name": "Самат"])
        defer { try? FileManager.default.removeItem(at: home.url) }

        let names = await Home.$scoped.withValue(home) {
            await SpeakerNamer.name(
                transcript: SessionFixture.transcript, title: nil, attendees: [], app: nil,
                into: dir)
        }

        #expect(model.callCount == 1)
        let onDisk = try #require(SpeakerNames.read(from: dir))
        #expect(onDisk.speakers["them A"]?.name == "Анна")
        #expect(onDisk.speakers["them A"]?.source == .manual)
        #expect(onDisk.speakers["me"]?.name == "Самат")
        #expect(names?.speakers["them A"]?.name == "Анна")
        let markdown = try String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Анна"))
        #expect(!markdown.contains("Фёдор:"))
    }
}
