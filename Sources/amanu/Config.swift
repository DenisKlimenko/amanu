import Foundation

/// Optional user config at ~/.config/amanu/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "auto",
///         "cloud": "assemblyai",
///         "language": "ru",
///         "assemblyai": { "api_key_path": "~/.config/amanu/keys/assemblyai" }
///       },
///       "mic_voice_processing": false,
///       "keep_audio": false,
///       "calendar": true,
///       "auto_record": { "enabled": true, "mic_activity": true, "calendar": false },
///       "summary": { "enabled": true, "backend": "auto", "language": "ru" },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript, the names and the
/// summary are written, or right after recording when transcription is
/// disabled.
enum Config {
    /// Where the file is. Asked of `Home` every time rather than fixed at
    /// startup, so that a test runs against a file of its own — see `Home`.
    static var path: URL { Home.current.configFile }

    static var defaultRoot: URL { Home.current.defaultRecordings }

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return Home.current.expanding(dir, isDirectory: true)
    }

    /// Shell command to spawn once a session is finished — transcript, names
    /// and summary — or right after recording, if transcription is disabled.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine: `auto` (default), a local engine, or a cloud
    /// provider by name — `assemblyai`, `openai`, or `elevenlabs`.
    ///
    /// `auto` means "the best one available right now": the cloud provider
    /// when there is a key and the API answers, parakeet otherwise. That
    /// ordering is deliberate — a cloud engine is better on Russian and tells
    /// apart several people sharing one channel, and parakeet needs neither
    /// network nor account, so it is what should catch a session recorded on
    /// a train.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "auto"
    }

    /// Which local engine `auto` falls back to. Kept separately for the same
    /// reason as the cloud provider: both cloud and local may be enabled, so
    /// the single `engine` value cannot remember both choices.
    static func transcriptionLocalEngine() -> String {
        let configured = transcription()?["local_engine"] as? String ?? "parakeet"
        guard localEngines.contains(configured) else {
            FileHandle.standardError.write(Data(
                "warning: unknown local engine \"\(configured)\" — using parakeet\n".utf8
            ))
            return "parakeet"
        }
        return configured
    }

    /// Which cloud engine `auto` reaches for. It only decides the provider —
    /// whether the cloud is used at all is `engine`. A provider named in
    /// `engine` wins over this setting.
    ///
    /// The two are separate settings because they answer separate questions,
    /// and the setup window asks them separately: a switch for "may audio
    /// leave this Mac", provider cards for "to whom". Turning the switch off
    /// and on again should not lose the answer to the second one.
    static func transcriptionCloudProvider() -> String {
        let configured = transcription()?["cloud"] as? String ?? "assemblyai"
        guard cloudEngines.contains(configured) else {
            FileHandle.standardError.write(Data(
                "warning: unknown cloud engine \"\(configured)\" — using assemblyai\n".utf8
            ))
            return "assemblyai"
        }
        return configured
    }

    /// The cloud engines, by the name they carry in the config and in
    /// transcript.json's provenance.
    static let cloudEngines: Set<String> = ["assemblyai", "openai", "elevenlabs"]
    static let localEngines: Set<String> = ["parakeet", "whisper", "gigaam"]

    /// OpenAI's transcription model. The default is the only one of theirs
    /// that returns timings and speakers; the setting exists for the day they
    /// ship a better one, not as a menu to browse.
    static func openAITranscriptionModel() -> String {
        guard let model = (transcription()?["openai"] as? [String: Any])?["model"] as? String,
              !model.isEmpty
        else { return "gpt-4o-transcribe-diarize" }
        return model
    }

    /// Parakeet model version: "v3" (multilingual, default) or "v2"
    /// (English-only, marginally higher recall on English).
    static func transcriptionModel() -> String {
        transcription()?["model"] as? String ?? "v3"
    }

    /// Two-letter code for the language meetings are *mostly* in, e.g. "ru".
    ///
    /// Not a pin. Both engines identify the language themselves; what this
    /// narrows is the shortlist they choose from, and English is on that
    /// shortlist whatever this says — see `MeetingLanguages`. nil means no
    /// expectation at all.
    static func transcriptionLanguage() -> String? {
        guard let code = transcription()?["language"] as? String, !code.isEmpty else { return nil }
        return code
    }

    /// Whether a meeting should feed the optional local streaming model while
    /// it is being recorded. This is deliberately opt-in: recording and the
    /// canonical post-meeting transcript do not depend on the extra model.
    ///
    /// The streaming model is local-only, so on a Mac without local models the
    /// answer is no whatever the config says — read here rather than at every
    /// call site, because a stored `true` from a migrated config is otherwise
    /// indistinguishable from a switch the person just flipped.
    static func liveTranscriptionEnabled() -> Bool {
        liveTranscriptionEnabled(in: load())
    }

    static func liveTranscriptionEnabled(in json: [String: Any]?) -> Bool {
        guard Platform.supportsLocalModels else { return false }
        let settings = json?["live_transcription"] as? [String: Any]
        return settings?["enabled"] as? Bool ?? false
    }

    /// amanu's own key drawer: one directory, mode 0700, one file per
    /// service, mode 0600.
    ///
    /// Keys used to be written to the shared locations — ~/.config/assemblyai,
    /// ~/.config/anthropic, ~/.config/openai — which several unrelated tools
    /// read and write. That is how a working AssemblyAI key became two bytes
    /// one evening and every meeting after it failed with HTTP 401. What amanu
    /// writes now belongs to amanu; what other tools keep is still *read*, so
    /// nobody has to paste a key twice.
    static var keysDir: URL { Home.current.keysDirectory }

    static var assemblyAIKeyPath: URL { keysDir.appendingPathComponent("assemblyai") }
    static var openAIKeyPath: URL { keysDir.appendingPathComponent("openai") }
    static var elevenLabsKeyPath: URL { keysDir.appendingPathComponent("elevenlabs") }
    static var anthropicKeyPath: URL { keysDir.appendingPathComponent("anthropic") }

    /// Where the rest of a machine's toolchain tends to keep the same secret.
    /// Read-only as far as amanu is concerned.
    ///
    /// Two filenames each, because both are in the wild: `token` is what the
    /// CLIs write, `api_key` is what people write by hand — and a key sitting
    /// in the second one while the window says "no key yet" is a person being
    /// asked to paste something they already have.
    static var assemblyAISharedKeyPaths: [URL] { sharedKeyPaths("assemblyai") }
    static var openAISharedKeyPaths: [URL] { sharedKeyPaths("openai") }
    static var elevenLabsSharedKeyPaths: [URL] { sharedKeyPaths("elevenlabs") }
    static var anthropicSharedKeyPaths: [URL] { sharedKeyPaths("anthropic") }

    private static func sharedKeyPaths(_ service: String) -> [URL] {
        Home.current.sharedKeyFiles(for: service)
    }

    /// The first of `paths` that holds something.
    private static func secret(atAnyOf paths: [URL]) -> String? {
        for path in paths {
            if let found = secret(at: path) { return found }
        }
        return nil
    }

    static func secret(at path: URL) -> String? {
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              !contents.trimmed.isEmpty
        else { return nil }
        return contents.trimmed
    }

    /// AssemblyAI key, in order: ASSEMBLYAI_API_KEY, an inline `api_key` in the
    /// config, a token file named by `api_key_path`, amanu's own key file, and
    /// finally the shared one this machine may already have.
    static func assemblyAIKey() -> String? {
        if let env = Home.current.variable("ASSEMBLYAI_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let inline = assemblyAI()?["api_key"] as? String, !inline.trimmed.isEmpty {
            return inline.trimmed
        }
        if let configured = (assemblyAI()?["api_key_path"] as? String)
            .map({ Home.current.expanding($0) }) {
            return secret(at: configured)
        }
        return secret(at: assemblyAIKeyPath) ?? secret(atAnyOf: assemblyAISharedKeyPaths)
    }

    /// Override AssemblyAI's default speech model. nil sends nothing and lets
    /// the API pick.
    static func assemblyAISpeechModel() -> String? {
        guard let model = assemblyAI()?["speech_model"] as? String, !model.isEmpty else {
            return nil
        }
        return model
    }

    private static func assemblyAI() -> [String: Any]? {
        transcription()?["assemblyai"] as? [String: Any]
    }

    static func elevenLabsKey() -> String? {
        if let env = Home.current.variable("ELEVENLABS_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        let settings = transcription()?["elevenlabs"] as? [String: Any]
        if let inline = settings?["api_key"] as? String, !inline.trimmed.isEmpty {
            return inline.trimmed
        }
        if let configured = (settings?["api_key_path"] as? String)
            .map({ Home.current.expanding($0) }) {
            return secret(at: configured)
        }
        return secret(at: elevenLabsKeyPath) ?? secret(atAnyOf: elevenLabsSharedKeyPaths)
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me".
    ///
    /// Off by default. VoiceProcessingIO is a duplex call route rather than an
    /// input-only effect: enabling it interrupts and attenuates what the person
    /// hears for the whole recording. Raw capture leaves playback untouched;
    /// per-track and multichannel transcription remove speaker echo later.
    /// Set true only when capture-time cancellation matters more than playback.
    static func micVoiceProcessing() -> Bool {
        micVoiceProcessing(in: load())
    }

    /// The same decision against supplied JSON, so an absent key's behavior is
    /// testable without reading or rewriting the person's real config file.
    static func micVoiceProcessing(in config: [String: Any]?) -> Bool {
        config?["mic_voice_processing"] as? Bool ?? false
    }

    /// Whether the transcript merge drops mic segments that duplicate
    /// overlapping system speech — the echo of a meeting played through the
    /// speakers into a raw mic. Costs nothing when there's no echo. Set false
    /// to keep every segment from both tracks. Runs on per-track and
    /// multichannel transcripts; a mixed transcript has no duplicate segment.
    static func transcriptEchoFilter() -> Bool {
        load()?["transcript_echo_filter"] as? Bool ?? true
    }

    /// Clean a derived microphone file before ASR without opening a playback
    /// device. Originals and the user's live call audio are never processed.
    static func offlineEchoCancellation() -> Bool {
        load()?["offline_echo_cancellation"] as? Bool ?? true
    }

    // MARK: - speaker names

    /// What to call the person doing the recording, instead of "me".
    ///
    /// Unset falls back to the machine's account name, but only when that
    /// reads as a person's name — see `SpeakerNamer.personName`.
    static func userName() -> String? {
        guard let name = load()?["user_name"] as? String, !name.trimmed.isEmpty else {
            return nil
        }
        return name.trimmed
    }

    /// Putting real names to the transcript's mechanical speaker labels.
    struct SpeakerNamesSettings {
        var enabled = true
        /// Which model to ask, in `LLMBackend`'s vocabulary.
        var backend = "auto"
        /// Anthropic model for this pass specifically. nil uses the summary's,
        /// which is the strong one — fine, but naming is an easier job than
        /// summarizing and doesn't need to cost the same.
        var model: String?
    }

    static func speakerNames() -> SpeakerNamesSettings {
        var settings = SpeakerNamesSettings()
        guard let json = load()?["speaker_names"] as? [String: Any] else { return settings }
        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["backend"] as? String, !v.isEmpty { settings.backend = v }
        if let v = json["model"] as? String, !v.isEmpty { settings.model = v }
        return settings
    }

    // MARK: - auto-record

    /// When and how amanu starts recording by itself.
    ///
    /// The defaults encode one asymmetry: a missed meeting costs a click, an
    /// unwanted recording costs privacy and disk. So starting takes sustained
    /// evidence (a known call app holding the mic for `startDelay`), stopping
    /// takes only `stopDelay`, short auto-recordings are thrown away entirely,
    /// and two independent backstops — silence and a hard cap — end a session
    /// no matter what the mic says.
    struct AutoRecordSettings {
        var enabled = true
        var micActivity = true
        var calendar = false
        /// How long a call app must hold the mic before this is a meeting.
        var startDelay: TimeInterval = 12
        /// How long nobody may hold the mic before the meeting is over.
        ///
        /// Short, because the condition is already strong: the call app has
        /// let go of the microphone *and* the far end has made no sound. A
        /// minute and a half of that used to be tacked onto the end of every
        /// recording for nothing.
        ///
        /// Not shorter than this, though. The mic is sampled once per
        /// `AutoRecordController.tick` and any held sample clears the idle
        /// clock, so 15 means four clean samples in a row — a whole tick of
        /// margin over the two that anything below 10 would come down to.
        /// The gap when a call app rebuilds its input unit (a device change
        /// mid-call) is a second or two, nowhere near that; an app that closes
        /// the input for longer would still fool this, and nobody has measured
        /// one.
        var stopDelay: TimeInterval = 15
        /// Auto-recordings shorter than this are deleted, not transcribed.
        var minDuration: TimeInterval = 45
        /// Hard ceiling on any auto-recording.
        var maxDuration: TimeInterval = 300 * 60
        /// Silence on *both* tracks for this long ends the session regardless
        /// of who holds the mic. The backstop that would have caught
        /// mygranola's overnight 15-hour run.
        var silenceStop: TimeInterval = 10 * 60
        /// Bundle-id prefixes that count as a call. Empty means any process.
        var callApps: [String] = MicActivityMonitor.defaultCallApps
        /// Extra bundle ids / process names to never count.
        var ignoreApps: [String] = []
    }

    static func autoRecord() -> AutoRecordSettings {
        var settings = AutoRecordSettings()
        guard let json = load()?["auto_record"] as? [String: Any] else { return settings }

        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["mic_activity"] as? Bool { settings.micActivity = v }
        if let v = json["calendar"] as? Bool { settings.calendar = v }
        if let v = json["start_delay_seconds"] as? Double { settings.startDelay = v }
        if let v = json["stop_delay_seconds"] as? Double { settings.stopDelay = v }
        if let v = json["min_duration_seconds"] as? Double { settings.minDuration = v }
        if let v = json["max_duration_minutes"] as? Double { settings.maxDuration = v * 60 }
        if let v = json["silence_stop_minutes"] as? Double { settings.silenceStop = v * 60 }
        // An explicit empty list is meaningful here ("count any app"), so this
        // reads presence rather than non-emptiness.
        if let v = json["apps"] as? [String] { settings.callApps = v }
        if let v = json["ignore_apps"] as? [String] { settings.ignoreApps = v }
        return settings
    }

    /// Whose audio lands on the far-end track: `app` (default) records only
    /// the call app's output, `all` records everything the Mac plays.
    ///
    /// `app` is better on both counts that matter. The transcript stops
    /// collecting music and notification dings, and — the reason this exists —
    /// "the far end has gone quiet" starts meaning the call ended rather than
    /// "nothing at all is playing on this machine". With `all`, a video opened
    /// after a meeting kept a recording alive for ten extra minutes
    /// (2026.08.18). Falls back to everything when the call app can't be
    /// identified: recording too much is a small wrong, recording nothing is
    /// the wrong that loses the meeting.
    static func systemAudioScope() -> String {
        load()?["system_audio"] as? String ?? "app"
    }

    /// Read the calendar to name sessions after the meeting they belong to.
    ///
    /// Separate from `auto_record.calendar`, which is about *starting* a
    /// recording from a calendar event. Naming is the cheaper, more broadly
    /// useful half: it costs the same one-time permission prompt but doesn't
    /// depend on your calendar being an accurate description of what you're
    /// actually doing.
    static func useCalendar() -> Bool {
        load()?["calendar"] as? Bool ?? true
    }

    /// Show amanu in the Dock (and in ⌘-Tab) rather than running as a
    /// menu-bar-only accessory. On by default: the menu bar hides its status
    /// item when it runs out of room, and a recorder whose only indicator can
    /// silently disappear is a recorder you can't trust.
    static func dockIcon() -> Bool {
        load()?["dock_icon"] as? Bool ?? true
    }

    /// Show amanu's feather in the menu bar, with the clock beside it while a
    /// meeting is being recorded. On by default, and it may be turned off
    /// together with the Dock icon: with neither, amanu is a program with no
    /// icon anywhere, and the way back to its window is to open Amanu again —
    /// from Spotlight or from Applications, which reaches the copy already
    /// running rather than starting a second one.
    static func menuBarIcon() -> Bool {
        load()?["menu_bar_icon"] as? Bool ?? true
    }

    /// Open the status window at launch. Off for anyone who'd rather start
    /// from the Dock icon each time.
    static func showWindowAtLaunch() -> Bool {
        load()?["window"] as? Bool ?? true
    }

    /// What language amanu's own windows are written in: `auto` (default,
    /// meaning the Mac's own languages decide), `en` or `ru`.
    ///
    /// Named at length rather than as `language`, because two settings called
    /// language already exist and answer different questions —
    /// `transcription.language` is what meetings are held in and
    /// `summary.language` is what summaries are written in. A bare `language`
    /// in this file would read as a third member of that family instead of as
    /// the one setting here that is about amanu's own words. See
    /// `InterfaceLanguage`.
    static func interfaceLanguage() -> String? {
        guard let value = load()?["interface_language"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Whether the audio outlives the transcript it was recorded for.
    ///
    /// Off by default, and that is a real trade rather than a tidy-up: a
    /// meeting is about a gigabyte an hour, and once it has been written down
    /// almost nobody plays it back. What it costs is the only cure for a bad
    /// transcript — a wrong language, a worse engine, a name the model got
    /// backwards — because re-transcribing needs the audio and nothing else
    /// can reconstruct it. Turn it on and the two temporary PCM tracks become
    /// one compact stereo M4A: mic on the left, system audio on the right.
    ///
    /// Only ever applies to a session that got its transcript. A session that
    /// failed keeps its audio whatever this says — that recording is the only
    /// copy of the meeting, and the next attempt is all it has.
    static func keepAudio() -> Bool {
        load()?["keep_audio"] as? Bool ?? false
    }

    // MARK: - summary

    /// Post-transcript summarization. `backend: auto` walks the chain in
    /// LLMBackend: the local `claude` CLI, the Anthropic API, the `codex` CLI,
    /// the OpenAI API, then ollama — subscriptions before metered keys.
    struct SummarySettings {
        var enabled = true
        var backend = "auto"
        /// Summarizing is where a cheap model quietly costs you something:
        /// a missed decision in a meeting you'll never listen to again. The
        /// difference between tiers is a few cents per meeting, so the default
        /// is the strong one.
        var openAIModel = "gpt-5"
        var openAIBaseURL = "https://api.openai.com/v1"
        /// Language for the summary itself; the transcript's own language is
        /// whatever was spoken. nil means "same language as the meeting".
        var language: String?
        var model = "claude-opus-5"
        var ollamaModel = "qwen3:8b"
        var ollamaBaseURL = "http://127.0.0.1:11434"
        var template = SummaryTemplate.default
        var apiKeyPath: URL?
    }

    static func summary() -> SummarySettings {
        summary(in: load())
    }

    /// The summary settings against supplied JSON, so defaults and custom
    /// templates are testable without reading or rewriting the person's real
    /// config file.
    static func summary(in root: [String: Any]?) -> SummarySettings {
        var settings = SummarySettings()
        guard let json = root?["summary"] as? [String: Any] else { return settings }

        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["backend"] as? String, !v.isEmpty { settings.backend = v }
        if let v = json["language"] as? String, !v.isEmpty { settings.language = v }
        if let v = json["model"] as? String, !v.isEmpty { settings.model = v }
        if let v = json["ollama_model"] as? String, !v.isEmpty { settings.ollamaModel = v }
        if let v = json["openai_model"] as? String, !v.isEmpty { settings.openAIModel = v }
        if let v = json["openai_base_url"] as? String, !v.trimmed.isEmpty {
            settings.openAIBaseURL = v.trimmed
        }
        if let v = json["ollama_base_url"] as? String, !v.trimmed.isEmpty {
            settings.ollamaBaseURL = v.trimmed
        }
        if let v = json["template"] as? String, !v.trimmed.isEmpty { settings.template = v }
        if let v = json["api_key_path"] as? String, !v.isEmpty {
            settings.apiKeyPath = Home.current.expanding(v)
        }
        return settings
    }

    /// OpenAI key, in order: OPENAI_API_KEY, a token file named by
    /// `summary.openai_api_key_path`, amanu's own key file, then the shared one.
    static func openAIKey() -> String? {
        if let env = Home.current.variable("OPENAI_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = (summaryJSON()?["openai_api_key_path"] as? String)
            .map({ Home.current.expanding($0) }) {
            return secret(at: configured)
        }
        return secret(at: openAIKeyPath) ?? secret(atAnyOf: openAISharedKeyPaths)
    }

    private static func summaryJSON() -> [String: Any]? {
        load()?["summary"] as? [String: Any]
    }

    /// Anthropic key, in order: ANTHROPIC_API_KEY, a token file named by
    /// `summary.api_key_path`, amanu's own key file, then the shared one.
    static func anthropicKey() -> String? {
        if let env = Home.current.variable("ANTHROPIC_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = summary().apiKeyPath { return secret(at: configured) }
        return secret(at: anthropicKeyPath) ?? secret(atAnyOf: anthropicSharedKeyPaths)
    }

    // MARK: - the file itself

    /// What is at `path`, told apart the three ways that matter.
    ///
    /// "No file" and "a file nobody can parse" used to be one answer, and every
    /// getter fell back to its default for both. For no file that is right.
    /// For a broken one it switched analytics back on for somebody who had
    /// turned it off and sent meetings to the cloud for somebody who had
    /// chosen a local engine — and the next write from any window replaced
    /// the whole file with the one key it was changing, which is how a stray
    /// comma would have cost somebody every setting they had.
    enum File {
        case absent
        case parsed([String: Any])
        /// There is a file and it is not a JSON object; the reason is the
        /// parser's own, for the person who has to find the comma.
        case unreadable(reason: String)
    }

    static func file() -> File {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
        // An empty file holds no decisions to lose, and refusing to write into
        // one would make `touch config.json` a trap.
        if String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .parsed([:])
        }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable(reason: "it is not a JSON object")
            }
            return .parsed(json)
        } catch {
            let parser = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return .unreadable(reason: parser ?? error.localizedDescription)
        }
    }

    /// Why the file cannot be read, or nil when it can — or when there is no
    /// file, which is a perfectly good config.
    static var unreadableReason: String? {
        if case .unreadable(let reason) = file() { return reason }
        return nil
    }

    /// What anything that could send a meeting somewhere throws while the
    /// file cannot be read.
    ///
    /// The whole pipeline after recording waits rather than only the cloud
    /// half of it: which engine is local and whether a summary is wanted are
    /// both answers in the file that cannot be read, and the defaults that
    /// stand in for them are `auto` and on. Recording itself needs none of
    /// that and goes on as normal; the sessions stay in the folder, which is
    /// the queue, and are picked up when the file can be read again.
    struct Unreadable: Error, CustomStringConvertible {
        let reason: String

        var description: String {
            "config.json can't be read (\(reason)) — transcription and summaries wait until it can"
        }
    }

    static func requireReadable() throws {
        if let reason = unreadableReason { throw Unreadable(reason: reason) }
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        switch file() {
        case .absent:
            return nil
        case .parsed(let json):
            return json
        case .unreadable(let reason):
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON (\(reason)) — using defaults\n".utf8
            ))
            return nil
        }
    }

    // MARK: - writing

    /// The config file as it is on disk, or an empty object when there isn't
    /// one yet — or when it cannot be read, which `file()` tells apart. The
    /// settings window reads this to show what has been set, as distinct from
    /// what merely defaults.
    static func raw() -> [String: Any] { load() ?? [:] }

    /// Set (or, with a nil value, clear) one setting, addressed by its path
    /// into the JSON — `["auto_record", "start_delay_seconds"]`.
    ///
    /// Clearing rather than writing the default is deliberate: a config that
    /// only contains what you changed keeps reading as a list of your
    /// decisions, and a default that improves later reaches you instead of
    /// being frozen into your file the first time you opened a window.
    /// Posted after the config file has been written, so that anything on
    /// screen showing a setting can read it again.
    ///
    /// Several surfaces render the same keys — the setup window, both tabs of
    /// the settings window, the status window's live-transcript switch — and
    /// nothing stops two of them being open at once. Without this the one
    /// nobody typed into keeps yesterday's answer until it is reopened, which
    /// looks exactly like the change not having been saved.
    ///
    /// It carries nothing: a listener redraws from the file, which is the
    /// only account of the settings any of them trusts anyway.
    static let didChange = Notification.Name("amanu.config.didChange")

    @discardableResult
    static func update(path: [String], value: Any?) -> Bool {
        guard let first = path.first else { return false }
        var json: [String: Any]
        switch file() {
        case .absent:
            json = [:]
        case .parsed(let parsed):
            json = parsed
        case .unreadable(let reason):
            // Writing now would mean writing the defaults plus this one key
            // over everything the person has in there. The file is theirs to
            // fix; until then nothing changes it.
            FileHandle.standardError.write(Data(
                ("not changing \(Self.path.path): it can't be read (\(reason)), and "
                    + "writing it now would replace everything in it\n").utf8
            ))
            return false
        }

        if path.count == 1 {
            if let value { json[first] = value } else { json.removeValue(forKey: first) }
        } else {
            var nested = json[first] as? [String: Any] ?? [:]
            nested = updated(nested, path: Array(path.dropFirst()), value: value)
            if nested.isEmpty { json.removeValue(forKey: first) } else { json[first] = nested }
        }
        switch write(json) {
        case .failed: return false
        case .unchanged: return true
        case .written:
            NotificationCenter.default.post(name: didChange, object: nil)
            Analytics.settingChanged(path: path, value: value)
            return true
        }
    }

    /// What a write did, which is not always what it was asked to do.
    private enum WriteResult {
        case written
        case unchanged
        case failed
    }

    private static func updated(
        _ object: [String: Any], path: [String], value: Any?
    ) -> [String: Any] {
        var object = object
        guard let first = path.first else { return object }
        if path.count == 1 {
            if let value { object[first] = value } else { object.removeValue(forKey: first) }
            return object
        }
        var nested = object[first] as? [String: Any] ?? [:]
        nested = updated(nested, path: Array(path.dropFirst()), value: value)
        if nested.isEmpty { object.removeValue(forKey: first) } else { object[first] = nested }
        return object
    }

    /// Put the config on disk, unless it is already there.
    ///
    /// The unchanged case is not an optimisation. A field commits when it
    /// loses focus, and focus is lost for reasons that are not edits — a tab
    /// changed, another window taking over, the window closing — so the same
    /// bytes were being written back regularly with nobody having decided
    /// anything. Nothing was lost, but the file's timestamp is the only claim
    /// anyone has that a setting was changed, and it was lying; and since
    /// every write wakes every open window to redraw, a write from inside a
    /// redraw is the start of a loop rather than a wasted syscall.
    private static func write(_ json: [String: Any]) -> WriteResult {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return .failed }
        // Sorted keys and a stable formatter, so identical settings really do
        // produce identical bytes rather than a diff in key order.
        if let current = try? Data(contentsOf: path), current == data { return .unchanged }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            return .written
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't write \(path.path): \(error)\n".utf8
            ))
            return .failed
        }
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return Home.current.expanding(cliOverride, isDirectory: true)
        }
        return recordingsDir() ?? defaultRoot
    }
}

private extension String {
    /// Keys read from files and the environment arrive with trailing
    /// newlines more often than not.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
