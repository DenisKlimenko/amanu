import Foundation

/// Which engine transcribes a session, and the prepared engines the queue
/// holds on to between sessions.
actor EngineResolver {
    /// An engine settled on in advance rather than chosen for the machine at
    /// the moment there is work. Only tests pass one: everything real wants
    /// the configured answer, and wants it decided late.
    private let fixedEngine: TranscriptionEngine?
    private(set) var engine: TranscriptionEngine?

    init(fixed: TranscriptionEngine? = nil) {
        fixedEngine = fixed
    }

    func prepared(for session: URL) async throws -> TranscriptionEngine {
        if let engine { return engine }
        if let fixedEngine {
            try await fixedEngine.prepare()
            engine = fixedEngine
            return fixedEngine
        }
        let configured = Self.configuredEngine(for: session)
        if !Self.knownEngines.contains(configured) {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — choosing automatically\n".utf8
            ))
        }
        let provider = Self.cloudProvider(configured: configured)
        let hasKey = CloudService(provider: provider).key() != nil
        if Config.localEngines.contains(configured), !Platform.supportsLocalModels, hasKey {
            FileHandle.standardError.write(Data(
                "warning: \(configured) needs Apple Silicon — transcribing with \(provider)\n".utf8
            ))
        }
        let engine: TranscriptionEngine
        switch Self.resolveEngine(
            configured: configured,
            hasKey: hasKey,
            localModels: Platform.supportsLocalModels
        ) {
        case .cloud:
            engine = try Self.cloudEngine(provider)
        case .local:
            let local = Config.localEngines.contains(configured)
                ? configured : Config.transcriptionLocalEngine()
            engine = Self.localEngine(named: local)
        case .cloudOrLocal:
            engine = await Self.bestAvailableEngine(
                provider, local: Config.transcriptionLocalEngine())
        case .unavailable:
            throw EngineUnavailable.noLocalModels
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Swap the held engine for the local one, after a cloud engine failed
    /// for want of a network.
    func fallBackToLocal(_ local: String) async throws -> TranscriptionEngine {
        await engine?.release()
        let replacement = Self.localEngine(named: local)
        engine = replacement
        try await replacement.prepare()
        return replacement
    }

    func release() async {
        await engine?.release()
        engine = nil
    }

    // MARK: - what the configuration adds up to

    static let knownEngines: Set<String> = Set(["auto"])
        .union(Config.cloudEngines)
        .union(Config.localEngines)

    static func configuredEngine(for session: URL) -> String {
        let requested = SessionState.value(
            session, SessionState.Key.transcriptionEngine) as? String
        return requested.flatMap { knownEngines.contains($0) ? $0 : nil }
            ?? Config.transcriptionEngine()
    }

    /// Which cloud service a configuration means. A configured engine naming
    /// a provider outright is that provider; anything else defers to the
    /// `cloud` setting, which is what the setup window's two cards write.
    static func cloudProvider(configured: String) -> String {
        Config.cloudEngines.contains(configured)
            ? configured
            : Config.transcriptionCloudProvider()
    }

    static func cloudEngine(_ provider: String) throws -> TranscriptionEngine {
        switch CloudService(provider: provider) {
        case .openAI: return try OpenAITranscriptionEngine()
        case .elevenLabs: return try ElevenLabsEngine()
        case .assemblyAI: return try AssemblyAIEngine()
        }
    }

    static func localEngine(named name: String) -> TranscriptionEngine {
        if name == "whisper" { return WhisperEngine() }
        if name == "gigaam" { return GigaAMEngine() }
        return ParakeetEngine()
    }

    static func isCloud(_ engine: TranscriptionEngine) -> Bool {
        switch engine.input {
        case .perTrack: return false
        case .multichannel, .mixed: return true
        }
    }

    /// Which engine the configuration adds up to, before the network is
    /// consulted. Pure so the whole matrix — including the Intel half of the
    /// universal binary, which cannot run a local model at all — is testable
    /// on whichever machine happens to be running the tests.
    enum EngineChoice: Equatable {
        /// Cloud, with no local rescue if it turns out to be unreachable.
        case cloud
        /// Local, no network involved.
        case local
        /// Cloud when it answers, local when it doesn't.
        case cloudOrLocal
        /// Neither: an Intel Mac with no API key. Nothing to run.
        case unavailable
    }

    static func resolveEngine(
        configured: String,
        hasKey: Bool,
        localModels: Bool
    ) -> EngineChoice {
        // An explicit provider keeps failing on a missing key rather than
        // quietly transcribing locally: the person asked for diarization.
        if Config.cloudEngines.contains(configured) { return .cloud }
        // An explicit parakeet on a Mac that cannot run it is the one place
        // we override a stated preference — the alternative is no transcript.
        if Config.localEngines.contains(configured) {
            if localModels { return .local }
            return hasKey ? .cloud : .unavailable
        }
        guard hasKey else { return localModels ? .local : .unavailable }
        return localModels ? .cloudOrLocal : .cloud
    }

    /// No engine this Mac can run. Not permanent — the missing half is an
    /// API key, and adding one is a thing a person does after reading this.
    enum EngineUnavailable: TranscriptionFailure, CustomStringConvertible {
        case noLocalModels

        var isPermanent: Bool { false }

        var description: String {
            "local transcription needs Apple Silicon, and this Mac has no key "
                + "for a cloud engine — put an AssemblyAI one in "
                + "\(Config.assemblyAIKeyPath.path) or an OpenAI one in "
                + "\(Config.openAIKeyPath.path), or an ElevenLabs one in "
                + "\(Config.elevenLabsKeyPath.path) (chmod 600), or set "
                + "ASSEMBLYAI_API_KEY / OPENAI_API_KEY / ELEVENLABS_API_KEY"
        }
    }

    /// Cloud when it's actually usable, local otherwise. Checked at the moment
    /// there is work rather than at launch, because the answer changes: the
    /// laptop that recorded a meeting on a train is transcribing it on a train.
    private static func bestAvailableEngine(
        _ provider: String,
        local: String = Config.transcriptionLocalEngine()
    ) async -> TranscriptionEngine {
        guard await CloudService(provider: provider).reachable() else {
            FileHandle.standardError.write(Data(
                "\(provider) unreachable — transcribing locally with \(local)\n".utf8
            ))
            return localEngine(named: local)
        }
        return (try? cloudEngine(provider)) ?? localEngine(named: local)
    }
}
