import Foundation
import Testing

@testable import amanu

/// A home of a test's own, for the tests that care what the config file says.
///
/// Every test already runs in a sandbox — `Home.process` is a temporary
/// directory in a test process — but that sandbox is one directory shared by
/// the whole run, and a test that writes to it races every other test that
/// reads it. These give one test, or every test in a suite, a fresh directory
/// with the config written in it, scoped through `Home.scoped` so that tests
/// running in parallel each see only their own.
///
///     @Test(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
///     func something() { … Config.offlineEchoCancellation() is false here … }
///
///     @Suite(.freshHome) struct Writes { … every test starts from no file … }
///
///     try withFreshHome(config: ["keep_audio": true]) { home in … }
///
/// The scope reaches everything the test awaits and every `Task {}` it
/// starts. It does not reach `Task.detached` or a dispatch queue, which read
/// the shared sandbox instead — never the real home.
struct FreshHome: TestTrait, SuiteTrait, TestScoping {
    /// The config file's text, or nil for no file at all.
    let config: String?

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // A suite is scoped through its tests, each in a directory of its own.
        guard testCase != nil else { return try await function() }
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        if let config { try home.writeConfig(text: config) }
        try await Home.$scoped.withValue(home) { try await function() }
    }
}

extension Trait where Self == FreshHome {
    /// A fresh home with no config file in it.
    static var freshHome: FreshHome { FreshHome(config: nil) }

    /// A fresh home whose config file says exactly `config` — which need not
    /// be valid JSON, for the tests that are about a file that is not.
    static func freshHome(config: String) -> FreshHome { FreshHome(config: config) }
}

/// The same thing for a stretch of one test.
func withFreshHome<R>(
    config: [String: Any]? = nil,
    _ body: (Home) throws -> R
) throws -> R {
    let home = Home.sandbox()
    defer { try? FileManager.default.removeItem(at: home.url) }
    if let config { try home.writeConfig(config) }
    return try Home.$scoped.withValue(home) { try body(home) }
}

func withFreshHome<R>(
    config: [String: Any]? = nil,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (Home) async throws -> R
) async throws -> R {
    let home = Home.sandbox()
    defer { try? FileManager.default.removeItem(at: home.url) }
    if let config { try home.writeConfig(config) }
    return try await Home.$scoped.withValue(home) { try await body(home) }
}

extension Home {
    /// Write the config file as JSON, the way `Config` itself would.
    func writeConfig(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try writeConfig(text: String(decoding: data, as: UTF8.self))
    }

    /// Write the config file as exactly these characters.
    func writeConfig(text: String) throws {
        try FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configFile, options: .atomic)
    }

    /// What is in the config file now, or nil for no file.
    var configText: String? {
        (try? Data(contentsOf: configFile)).map { String(decoding: $0, as: UTF8.self) }
    }
}
