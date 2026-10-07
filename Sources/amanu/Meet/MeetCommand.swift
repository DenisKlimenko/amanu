import ArgumentParser
import Foundation

/// Google Meet speaker names: the browser half.
///
/// The extension in `Extensions/meet` cannot write files, so the browser
/// starts this program as a native-messaging host and hands it the timeline a
/// message at a time. `install` tells each installed Chromium-family browser
/// where the host is; `host` is what they then start.
struct MeetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meet",
        abstract: "Name Google Meet speakers from the browser extension's timeline.",
        subcommands: [Install.self, Host.self]
    )

    /// The name the extension connects to, and the extension allowed to.
    /// The ID is fixed by the public key in the extension's manifest, so it is
    /// the same on every machine that loads it unpacked.
    static let hostName = "me.samat.amanu.meet"
    static let extensionID = "nbighglgalgflgobaljbogmopffnjohd"

    /// Where each browser looks for hosts, under Application Support. A
    /// browser that is not installed has no directory, and is skipped rather
    /// than having one created for it.
    static let browsers: [(name: String, profile: String)] = [
        ("Dia", "Dia/User Data"),
        ("Google Chrome", "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Arc", "Arc/User Data"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
    ]

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register the native-messaging host with every installed Chromium browser."
        )

        @Flag(name: .long, help: "Remove the registration instead.")
        var uninstall = false

        func run() throws {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let manifest = try JSONSerialization.data(withJSONObject: [
                "name": MeetCommand.hostName,
                "description": "amanu — who Google Meet shows as speaking",
                // The browser starts exactly this file, with the extension's
                // origin as the only argument; `Amanu.main` knows what that
                // means.
                "path": Runtime.executableURL.path,
                "type": "stdio",
                "allowed_origins": ["chrome-extension://\(MeetCommand.extensionID)/"],
            ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

            var touched = 0
            for browser in MeetCommand.browsers {
                let profile = support.appendingPathComponent(browser.profile, isDirectory: true)
                guard FileManager.default.fileExists(atPath: profile.path) else { continue }
                let hosts = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                let file = hosts.appendingPathComponent("\(MeetCommand.hostName).json")
                if uninstall {
                    guard (try? FileManager.default.removeItem(at: file)) != nil else { continue }
                    print("✓ \(browser.name): removed")
                } else {
                    try FileManager.default.createDirectory(
                        at: hosts, withIntermediateDirectories: true)
                    try manifest.write(to: file, options: .atomic)
                    print("✓ \(browser.name): \(file.path)")
                }
                touched += 1
            }
            guard touched > 0 else {
                throw CleanExit.message(uninstall
                    ? "nothing was registered"
                    : "no Chromium-family browser found in \(support.path)")
            }
            if !uninstall {
                print("""

                Now load the extension, once per browser profile you join Meet from:
                open the browser's extensions page (dia://extensions, chrome://extensions),
                turn on Developer mode, choose Load unpacked, and pick Extensions/meet
                from the amanu source tree. Restart the browser afterwards.
                """)
            }
        }
    }

    struct Host: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The native-messaging host itself. Started by the browser, not by you.",
            shouldDisplay: false
        )

        /// The calling extension's origin. Chrome also passes a window handle
        /// on Windows, which is why this is a list.
        @Argument var caller: [String] = []

        func run() throws {
            try MeetHost.serve()
        }
    }
}

/// The host's side of native messaging: a 32-bit length in native byte
/// order, then that many bytes of JSON, repeated until the browser closes the
/// pipe. Nothing is ever written back — stdout belongs to the protocol, and a
/// stray byte on it makes the browser drop the connection.
enum MeetHost {
    /// Chrome's own limit for a message to a host is 64 MB; ours are a few
    /// hundred bytes. Anything near the ceiling is not ours.
    static let maxMessage = 1 << 20

    /// Append every message to a new file in `directory`, one JSON object per
    /// line, named for the moment the connection opened. Earlier connections'
    /// files are never deleted: a session transcribed again, however long
    /// after, is named from them.
    static func serve(
        input: FileHandle = .standardInput,
        directory: URL = MeetSpeakers.directory,
        now: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "\(Int(now.timeIntervalSince1970 * 1000)).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }

        var wrote = false
        while let message = try readMessage(from: input) {
            // Re-serialized rather than copied, so a message with a newline
            // in it cannot split one line into two.
            guard let object = try? JSONSerialization.jsonObject(with: message),
                  object is [String: Any],
                  let line = try? JSONSerialization.data(withJSONObject: object)
            else { continue }
            try output.write(contentsOf: line + Data([0x0A]))
            wrote = true
        }
        if !wrote { try? FileManager.default.removeItem(at: file) }
    }

    /// One message, or nil at the end of the stream.
    static func readMessage(from input: FileHandle) throws -> Data? {
        guard let header = try read(4, from: input) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length <= maxMessage else {
            throw ValidationError("native message of \(length) bytes is not from the extension")
        }
        return try read(length, from: input)
    }

    /// Exactly `count` bytes, however many reads that takes; nil if the pipe
    /// closed first.
    private static func read(_ count: Int, from input: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }
}
