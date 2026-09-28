import Foundation
import Testing

@testable import amanu

@Suite("Command-line link installation")
struct AgentCLITests {
    @Test("A Homebrew-managed command prevents a duplicate private link")
    func homebrewLinkWins() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("Applications/Amanu.app/Contents/MacOS/Amanu")
        let homebrewCLI = root.appendingPathComponent("homebrew/bin/amanu")
        let privateCLI = root.appendingPathComponent("home/.local/bin/amanu")
        try fm.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: homebrewCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("amanu".utf8).write(to: executable)
        try fm.createSymbolicLink(at: homebrewCLI, withDestinationURL: executable)
        defer { try? fm.removeItem(at: root) }

        let changed = try AgentCLI.install(
            at: privateCLI,
            to: executable,
            managedCLIs: [homebrewCLI],
            persistent: true
        ).get()

        #expect(!changed)
        #expect(!fm.fileExists(atPath: privateCLI.path))
    }

    // MARK: - an existing file at the link's path

    private static func sandbox() throws -> (root: URL, executable: URL, cli: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "amanu-cli-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("Applications/Amanu.app/Contents/MacOS/Amanu")
        try fm.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new amanu".utf8).write(to: executable)
        return (root, executable, root.appendingPathComponent("home/.local/bin/amanu"))
    }

    /// Midday UTC, so the date in the backup's name is the same wherever the
    /// test runs.
    private static let day = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    private static func install(_ cli: URL, _ executable: URL) throws -> Bool {
        try AgentCLI.install(
            at: cli, to: executable, managedCLIs: [], persistent: true, now: day
        ).get()
    }

    /// Somebody's own `amanu` — an older build copied there by hand, or a
    /// script of the same name — is theirs, and is moved aside with the date
    /// rather than written over.
    @Test("A real binary in the way is kept under a dated name and replaced by the link")
    func aRealBinaryIsBackedUp() throws {
        let fm = FileManager.default
        let (root, executable, cli) = try Self.sandbox()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old amanu".utf8).write(to: cli)

        #expect(try Self.install(cli, executable))

        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == executable.path)
        let backup = cli.deletingLastPathComponent().appendingPathComponent("amanu.legacy-20260928")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "old amanu")
    }

    @Test("A backup name already taken gets a number instead of failing or overwriting")
    func backupNamesAreNumbered() throws {
        let fm = FileManager.default
        let (root, executable, cli) = try Self.sandbox()
        defer { try? fm.removeItem(at: root) }
        let bin = cli.deletingLastPathComponent()
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("first backup".utf8).write(to: bin.appendingPathComponent("amanu.legacy-20260928"))
        try Data("second backup".utf8)
            .write(to: bin.appendingPathComponent("amanu.legacy-20260928-2"))
        try Data("old amanu".utf8).write(to: cli)

        #expect(try Self.install(cli, executable))

        #expect(try String(
            contentsOf: bin.appendingPathComponent("amanu.legacy-20260928"), encoding: .utf8)
            == "first backup")
        #expect(try String(
            contentsOf: bin.appendingPathComponent("amanu.legacy-20260928-2"), encoding: .utf8)
            == "second backup")
        #expect(try String(
            contentsOf: bin.appendingPathComponent("amanu.legacy-20260928-3"), encoding: .utf8)
            == "old amanu")
        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == executable.path)
    }

    @Test("A link that already points here is left alone; one pointing elsewhere is replaced")
    func existingLinks() throws {
        let fm = FileManager.default
        let (root, executable, cli) = try Self.sandbox()
        defer { try? fm.removeItem(at: root) }

        // No directory yet: it is made.
        #expect(try Self.install(cli, executable))
        #expect(try !Self.install(cli, executable), "A correct link is not a change.")

        let elsewhere = root.appendingPathComponent("Old.app/Contents/MacOS/Amanu")
        try fm.removeItem(at: cli)
        try fm.createSymbolicLink(at: cli, withDestinationURL: elsewhere)
        #expect(try Self.install(cli, executable))
        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == executable.path)
        let backups = try fm.contentsOfDirectory(atPath: cli.deletingLastPathComponent().path)
        #expect(backups == ["amanu"], "A link is a pointer, not anybody's file: \(backups)")
    }

    @Test("A copy that cannot persist anything installs nothing")
    func nonPersistentRunsInstallNothing() throws {
        let fm = FileManager.default
        let (root, executable, cli) = try Self.sandbox()
        defer { try? fm.removeItem(at: root) }

        let changed = try AgentCLI.install(
            at: cli, to: executable, managedCLIs: [], persistent: false, now: Self.day
        ).get()
        #expect(!changed)
        #expect(!fm.fileExists(atPath: cli.deletingLastPathComponent().path))
    }
}
