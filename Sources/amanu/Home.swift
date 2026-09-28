import Darwin
import Foundation

/// Everything amanu keeps for the person running it, and everything it may
/// borrow from their machine: the config file, the setup and analytics state
/// beside it, the key drawer, the key files other tools share, the API keys in
/// the environment, the command-line tools a login shell can find, and the
/// language models those tools and keys reach.
///
/// It exists so that a test cannot touch any of that. Every one of those
/// places used to be a `static let` under the real home directory, which meant
/// the suite read the developer's own `config.json` — sixty window tests drew
/// whatever that file said, and a transcription test finishing a fixture
/// session walked `LLMBackend.available` far enough to find the developer's
/// `claude` CLI. Only the fixtures' status flags stood between a test and a
/// real model reading a fixture transcript.
///
/// So the answer is decided in two layers:
///
/// - `process` is the home for anything that is not told otherwise. In the
///   application and the command line it is the person's own. In a test
///   process it is a sandbox: a temporary directory, an empty environment, no
///   tool discovery and no language models. That is decided by what the code
///   is linked into (see `runsInsideTests`) rather than by a flag somebody has
///   to remember, which is how banners are kept quiet too.
/// - `scoped` is a task-local override, so one test can run against a config
///   of its own while another runs in parallel against a different one.
///
/// Task-locals are inherited by child tasks and by `Task {}`, and not by
/// `Task.detached` or by a `DispatchQueue`. Work that hops onto either reads
/// `process` instead of the scoped home — which in a test process is still the
/// sandbox, so the hop can lose a test's particular config but can never reach
/// the real one.
struct Home: Sendable {
    /// What stands for `~`.
    let url: URL
    /// The environment API keys are read from, or nil for the live process
    /// environment.
    let environment: [String: String]?
    /// Whether amanu may go looking at this machine: login shells, `--version`
    /// runs, Ollama's port.
    let discoversTools: Bool
    /// What `LLMBackend.available` hands out, by preference; nil is the real
    /// chain of CLIs, keys and Ollama. A sandbox answers with nothing, and a
    /// test that wants a model to talk to supplies its own fake here.
    let languageModels: (@Sendable (_ preference: String) -> [LLMBackend])?

    init(
        url: URL,
        environment: [String: String]?,
        discoversTools: Bool,
        languageModels: (@Sendable (_ preference: String) -> [LLMBackend])?
    ) {
        self.url = url
        self.environment = environment
        self.discoversTools = discoversTools
        self.languageModels = languageModels
    }

    // MARK: - which home

    /// The home in force for the code that is running now.
    static var current: Home { scoped ?? process }

    /// A narrower home for one task and everything it starts — see the type's
    /// own comment for what does not inherit it.
    @TaskLocal static var scoped: Home?

    /// The home for anything not scoped to another.
    static let process: Home = runsInsideTests ? .sandbox() : .person

    /// The person's own home, exactly as amanu always read it.
    static var person: Home {
        Home(
            url: FileManager.default.homeDirectoryForCurrentUser,
            environment: nil,
            discoversTools: true,
            languageModels: nil)
    }

    /// A home that belongs to nobody: an empty directory of its own under the
    /// temporary directory, no environment, no tools and no models.
    static func sandbox(
        at url: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-home-\(UUID().uuidString)", isDirectory: true),
        languageModels: @escaping @Sendable (_ preference: String) -> [LLMBackend] = { _ in [] }
    ) -> Home {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Home(
            url: url, environment: [:], discoversTools: false, languageModels: languageModels)
    }

    /// Whether this code was linked into a test bundle.
    ///
    /// Asked of the image the code itself lives in, not of the process: a
    /// SwiftPM test run is `swiftpm-testing-helper` or `xctest` loading
    /// `amanuPackageTests.xctest`, and amanu's code is inside that bundle's
    /// executable. The application and the command line are never loaded from
    /// an `.xctest` bundle, so the answer cannot be true for them — the same
    /// kind of guarantee the missing bundle gives the banners, and pinned by a
    /// test in the same way.
    static let runsInsideTests: Bool = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return false }
        return String(cString: name).contains(".xctest/")
    }()

    // MARK: - what lives here

    /// One environment variable, from this home's environment.
    func variable(_ name: String) -> String? {
        (environment ?? ProcessInfo.processInfo.environment)[name]
    }

    var configDirectory: URL {
        url.appendingPathComponent(".config/amanu", isDirectory: true)
    }

    var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    var setupFile: URL { configDirectory.appendingPathComponent("setup.json") }
    var analyticsIdentityFile: URL { configDirectory.appendingPathComponent("analytics.json") }
    var analyticsPendingFile: URL {
        configDirectory.appendingPathComponent("analytics-pending.json")
    }
    var keysDirectory: URL { configDirectory.appendingPathComponent("keys", isDirectory: true) }

    /// Where other tools keep the same secret — see `Config.sharedKeyPaths`.
    func sharedKeyFiles(for service: String) -> [URL] {
        ["token", "api_key"].map { url.appendingPathComponent(".config/\(service)/\($0)") }
    }

    var defaultRecordings: URL { url.appendingPathComponent("Recordings", isDirectory: true) }

    /// A path as a person writes it, with `~` meaning this home.
    ///
    /// Not `expandingTildeInPath`, which always means the real one: a test's
    /// config naming `~/.config/anthropic/token` would otherwise read the
    /// developer's own key through a sandbox that was supposed to have none.
    func expanding(_ path: String, isDirectory: Bool = false) -> URL {
        let expanded: String
        if path == "~" {
            expanded = url.path
        } else if path.hasPrefix("~/") {
            expanded = url.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory)
    }

    /// The other direction, for showing a path the way a person would write
    /// it: under this home it starts with `~`.
    func abbreviating(_ path: String) -> String {
        let home = url.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
