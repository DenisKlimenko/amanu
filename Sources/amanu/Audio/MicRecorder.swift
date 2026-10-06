// @preconcurrency: AVFAudio predates Sendable annotation, and its callback
// types (AVAudioNodeTapBlock, AVAudioConverterInputBlock) are declared
// @Sendable while the buffers they hand you are not. Both run synchronously on
// the thread that invokes them, so the diagnostics are annotation debt in the
// SDK rather than races here — the state genuinely shared across threads is
// the locked LockedState below.
@preconcurrency import AVFoundation
import Foundation
import os.lock

/// Records the microphone to a mono PCM file. Buffers stream straight to
/// disk — nothing is held in memory, so session length is unbounded.
///
/// Raw capture is the default so recording never reroutes or attenuates what
/// the person hears. It reads the microphone itself, through an IO proc
/// (`MicIOProc`) that is started and stopped off main. With voice processing
/// explicitly enabled, an AVAudioEngine runs Apple's echo canceller, which
/// subtracts speaker playback from the mic. VoiceProcessingIO is a duplex
/// unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
///
/// A route change mid-meeting rebuilds capture, and the rebuild keeps both
/// of those properties: the chosen processing mode and the same wall clock.
/// Losing either is silent at the time and obvious a day later — see
/// `restartCapture`.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)
        case voiceProcessingUnavailable(Error)
        case noMicrophone
        case deviceUnreadable(AudioObjectID)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            case .voiceProcessingUnavailable(let e): return "mic voice processing unavailable: \(e)"
            case .noMicrophone: return "no microphone to record"
            case .deviceUnreadable(let d): return "can't read the input format of mic device \(d)"
            case .ioProcCreationFailed(let s): return "mic IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "mic device start failed (OSStatus \(s))"
            }
        }
    }

    /// One mid-session capture restart: something reconfigured the input
    /// device under us — a call app engaging voice processing, headphones
    /// connecting, AirPods coming out of an ear — and capture had to be
    /// rebuilt on the new route.
    ///
    /// Recorded because the two things that go wrong here are invisible while
    /// they happen. On 2026.08.20 one call restarted twice; the only surviving
    /// evidence was two short pads in the waveform, and the cost of reading it
    /// that way was an afternoon of cross-correlating the tracks.
    struct Restart {
        let at: Date
        /// Dead span written as silence, filled in by the first buffer the new
        /// capture delivers — nothing before that knows how long the route
        /// took to come back.
        var gapMs: Int?
        /// Silence actually written, when less than the gap: see
        /// `longestPad`. Absent when the whole gap was padded.
        var paddedMs: Int?
        var voiceProcessing: Bool?
        var inputWas: String?
        var inputNow: String?
        var outputWas: String?
        var outputNow: String?
        /// Channels the microphone came back with; see `Capture.inputChannels`.
        var inputChannels: Int?

        func meta(iso: ISO8601DateFormatter) -> [String: Any] {
            var fields: [String: Any] = ["at": iso.string(from: at)]
            if let gapMs { fields["gap_ms"] = gapMs }
            if let paddedMs { fields["padded_ms"] = paddedMs }
            if let voiceProcessing { fields["voice_processing"] = voiceProcessing }
            if let inputWas { fields["input_was"] = inputWas }
            if let inputNow { fields["input_now"] = inputNow }
            if let outputWas { fields["output_was"] = outputWas }
            if let outputNow { fields["output_now"] = outputNow }
            if let inputChannels { fields["input_channels"] = inputChannels }
            return fields
        }
    }

    /// What the microphone capture actually did, rather than what the config
    /// asked it to do. The distinction is the point of the experiment: a voice
    /// route can refuse to start or can begin with signal and later fall back
    /// to raw capture after a liveness failure or restart storm.
    struct Capture {
        let requestedVoiceProcessing: Bool
        let initialVoiceProcessing: Bool
        let finalVoiceProcessing: Bool
        let inputDevice: String?
        let outputDevice: String?
        let sampleRate: Double?
        let channels: Int?
        let sampleFormat: String?
        /// Channels the microphone came in, where `channels` is the track's
        /// and always one. Three is the built-in microphone while another
        /// process runs voice processing on it, the shape `rawGain(for:)`
        /// amplifies — and the only trace of it that lasts: the format line
        /// goes to a stderr nobody keeps when macOS launches the app.
        let inputChannels: Int?

        var meta: [String: Any] {
            var fields: [String: Any] = [
                "requested_voice_processing": requestedVoiceProcessing,
                "initial_voice_processing": initialVoiceProcessing,
                "final_voice_processing": finalVoiceProcessing,
                "fell_back_to_raw": requestedVoiceProcessing
                    && (!initialVoiceProcessing || !finalVoiceProcessing),
            ]
            if let inputDevice { fields["input_device"] = inputDevice }
            if let outputDevice { fields["output_device"] = outputDevice }
            if let sampleRate { fields["sample_rate_hz"] = Int(sampleRate.rounded()) }
            if let channels { fields["channels"] = channels }
            if let sampleFormat { fields["sample_format"] = sampleFormat }
            if let inputChannels { fields["input_channels"] = inputChannels }
            return fields
        }
    }

    /// The voice-processing engine, while that is what is capturing. Raw
    /// capture never builds one: an engine's input node joins the default
    /// device's aggregate the moment it is touched, and that is where the
    /// waits on AirPods were (see `MicIOProc`).
    private var engine: AVAudioEngine?
    /// The raw capture, while that is what is capturing. Opened, checked and
    /// stopped on `deviceQueue` only, because any of that can wait on the
    /// device, and main must never wait on one.
    private var proc: MicIOProc?
    private let deviceQueue = DispatchQueue(label: "me.samat.amanu.mic-device")
    /// Where raw capture's buffers are written, one at a time.
    private let ioQueue = DispatchQueue(label: "me.samat.amanu.mic-io")
    private let liveAudio = LiveAudioBufferRelay()
    private var url: URL?
    private(set) var isRecording = false
    private var requestedVoiceProcessing = false
    private var initialVoiceProcessing = false
    private var finalVoiceProcessing = false
    private var initialInputDevice: String?
    private var initialOutputDevice: String?
    private var initialInputChannels: Int?
    private var captureSampleRate: Double?
    private var captureChannels: Int?
    private var captureSampleFormat: String?

    var capture: Capture {
        Capture(
            requestedVoiceProcessing: requestedVoiceProcessing,
            initialVoiceProcessing: initialVoiceProcessing,
            finalVoiceProcessing: finalVoiceProcessing,
            inputDevice: initialInputDevice,
            outputDevice: initialOutputDevice,
            sampleRate: captureSampleRate,
            channels: captureChannels,
            sampleFormat: captureSampleFormat,
            inputChannels: initialInputChannels)
    }

    // Thread-safe shared state: accessed from the main thread, the device
    // queue and the capture callbacks without further sync.
    private struct LockedState {
        var file: AVAudioFile?
        /// What capture writes through. Replaced whenever `file` is, and
        /// kept across a mid-session rebuild along with it.
        var writer: TrackWriter?
        var firstBufferAt: Date?
        var lastBufferAt: Date?
        var lastSoundAt: Date?
        var levelMeasurable = true
        var muted = false
        /// Every restart, and the dead span still open. Opened on the main
        /// thread when capture is retired, closed by the callback whose
        /// buffer ends it.
        var log = RestartLog()
        /// Which capture may write. Moved on whenever one is retired — by a
        /// restart, or by stop — so that what its device still delivers on
        /// the way down is dropped. Written after the gap opened for the
        /// capture replacing it, a single such buffer would close that gap
        /// before the new capture had delivered anything, and the track would
        /// lose the time the restart took.
        var generation = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    private var file: AVAudioFile? {
        get { state.withLockUnchecked { $0.file } }
        set {
            state.withLockUnchecked {
                $0.file = newValue
                $0.writer = newValue.map { TrackWriter(file: $0, label: "mic") }
            }
        }
    }

    /// The writer, for buffers of the capture that is current — nil for one
    /// that a restart or stop has retired since it started.
    private func writer(for generation: Int) -> TrackWriter? {
        state.withLockUnchecked { $0.generation == generation ? $0.writer : nil }
    }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    var firstBufferAt: Date? { state.withLock { $0.firstBufferAt } }

    /// Wall-clock time of the most recent captured buffer. When a device
    /// reconfiguration stops capture, the span from here to the restart is
    /// written as silence so downstream timestamps stay wall-clock aligned.
    /// Written from the capture callbacks and read on main during a restart,
    /// so it belongs under the same lock as the rest.
    private var lastBufferAt: Date? {
        get { state.withLock { $0.lastBufferAt } }
        set { state.withLock { $0.lastBufferAt = newValue } }
    }

    /// Wall-clock time of the last buffer that carried something louder than
    /// the noise floor. nil means nothing audible has been captured yet.
    var lastSoundAt: Date? { state.withLock { $0.lastSoundAt } }

    /// False once a buffer arrived in a sample format we can't measure —
    /// callers must then treat "silent" as "unknown" rather than as silence.
    var levelMeasurable: Bool { state.withLock { $0.levelMeasurable } }

    /// Every route change this session survived, in order. Read on stop, for
    /// meta.json.
    var restarts: [Restart] { state.withLock { $0.log.entries } }

    /// While muted, capture continues but silence is written in place of the
    /// real audio: the file keeps growing on the wall clock, so timestamps
    /// after the pause stay true, and nothing said in the room is recorded.
    var isMuted: Bool {
        get { state.withLock { $0.muted } }
        set { state.withLock { $0.muted = newValue } }
    }

    // Main-thread only: the observer passes its changes to the main queue,
    // and raw capture reports there, so these need no lock.
    private var configObserver: NSObjectProtocol?
    /// A rebuild is scheduled or under way — for raw capture, until its
    /// device has started or failed to — and nothing else may begin one.
    private var restartPending = false
    /// The route the current capture attached to, so a restart can say what
    /// changed rather than only that something did.
    private var inputDevice: String?
    private var outputDevice: String?
    private var inputChannels: Int?
    /// True while capture is writing into a file that was already open — a
    /// mid-session rebuild. It decides what a failure may throw away: at
    /// the start of a session, a silent prefix; mid-session, a meeting.
    private var attachedReusingFile = false
    /// When the current capture finished attaching, for the settle window
    /// below.
    private var attachedAt = Date.distantPast
    /// The call app families this session follows, and the device that choice
    /// currently resolves to — what capture is bound to rather than what it
    /// inherited.
    private var followedCallApps: [String] = []
    private var boundDevice: AudioObjectID?
    /// Microphones that refused this session; see `RefusedDevices`.
    private var refused = RefusedDevices()
    /// Whether the last attach bound a microphone other than the default —
    /// what `attachWithFallbacks` asks after a failure.
    private var boundChosenDevice = false
    /// Whether raw capture is up: set once its device has started, cleared
    /// when it is retired.
    private var rawRunning = false
    /// Whether capture has come up yet this session. What it first came up
    /// as is what `capture` reports.
    private var startedOnce = false
    /// Listener on the system default input, because a default that changes
    /// under running capture changes nothing else: capture stays on the
    /// device it was opened on, and nothing is posted at all.
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    /// How long a new microphone has to still be the answer before we move to
    /// it. A route in the middle of changing answers differently from one
    /// second to the next, and each move costs silence in the track.
    private static let routeSettle: TimeInterval = 1.5

    /// How long after an attach a configuration change may be our own doing.
    /// Enabling the voice unit reconfigures the input device — it builds an
    /// aggregate around it — and that posts the very notification this class
    /// restarts on, so restarting for it would start the next one.
    ///
    /// The window decides nothing by itself, because it cannot: the same
    /// notification is posted when the engine has genuinely stopped, and at
    /// the moment it arrives the two look alike. Inside the window the answer
    /// waits for `settleDeadline`, by which time a healthy engine is
    /// delivering buffers and a stopped one is not. Reading the window as
    /// "ignore it" costs a mic track — measured on 20 August 2026: 43 seconds
    /// of a 67-second recording silent, and nothing in the log but the line
    /// saying the change had been ignored.
    private static let settleWindow: TimeInterval = 1.5
    /// When that question gets answered, measured from the attach. Long enough
    /// to cover a voice-processing route's warm-up — 1.7 to 2.8 s to the first
    /// buffer on this Mac — and the worst case for how much audio genuinely
    /// dead capture costs before it is rebuilt.
    private static let settleDeadline: TimeInterval = 5
    /// A buffer this recent means capture is alive.
    private static let aliveWithin: TimeInterval = 1
    /// Restarts within this window of each other, and the number of them that
    /// says the settle window isn't holding. Past it the route gets raw
    /// capture for the rest of the session: a track with an echo on it is a
    /// bad recording, a track rebuilt every two seconds is no recording.
    private static let stormWindow: TimeInterval = 30
    private static let stormLimit = 3

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back. The dispatch to main
    // in fallBackToRaw creates a happens-before, so these need no lock.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic as PCM in `url` (use a .caf extension — CAF
    /// needs no finalization pass, so a crash loses nothing written).
    ///
    /// `callApps` are the bundle-id families this session is following, and
    /// they decide which microphone is captured: the one the call app is
    /// listening to, falling back to the system default. Pass them again
    /// through `follow(callApps:)` when the session's idea of the call
    /// changes.
    ///
    /// Raw capture comes up off main, so this returns before it has: it
    /// throws only when there is no microphone at all, and one that will not
    /// start is asked again every two seconds, while the watchdog reports a
    /// mic track that is not growing.
    func start(writingTo url: URL, callApps: [String] = []) throws {
        guard !isRecording else { return }
        self.url = url
        followedCallApps = callApps
        requestedVoiceProcessing = Config.micVoiceProcessing()
        restartPending = false
        startedOnce = false
        try attachWithFallbacks(voiceProcessing: requestedVoiceProcessing, reusingFile: false)
        isRecording = true
        // The engine is up by now; raw capture reports when its device is.
        if engine != nil { noteStarted() }
        // A call app (FaceTime, Zoom) grabbing the mic reconfigures the input
        // device and stops the engine mid-session; without this observer the
        // track just ends there (2026.07.28: 1.7s mic on a 19min call). Raw
        // capture hears the same from the device itself.
        configObserver = Self.observeConfigurationChanges { [weak self] changed in
            guard let self, let engine = self.engine, changed === engine else { return }
            self.handleConfigChange()
        }
        listenForDefaultInputChanges()
    }

    /// Hand every engine's configuration change to `body` on the main queue.
    ///
    /// Taken on the posting thread and passed on, never observed with
    /// `queue: .main`. The engine posts from a serial queue of its own, and a
    /// queued observer makes that post wait for main — while a restart, which
    /// releases the old engine on main, waits for the same queue in
    /// `-[AVAudioEngine dealloc]`. A second change arriving mid-restart hung
    /// amanu for good on 29 September 2026 (docs/pitfalls.md).
    static func observeConfigurationChanges(
        _ body: @escaping @Sendable (AVAudioEngine?) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { note in
            let engine = note.object as? AVAudioEngine
            DispatchQueue.main.async { body(engine) }
        }
    }

    /// Follow these call app families from now on. The route is re-examined
    /// immediately: a second app joining the call may well be the one holding
    /// the microphone.
    func follow(callApps families: [String]) {
        guard families != followedCallApps else { return }
        followedCallApps = families
        checkRoute()
    }

    /// Re-examine which microphone we ought to be on, and move if it is not
    /// the one we are on — or if the one we are on has stopped delivering.
    /// Called on every route notification and on the session's own timer,
    /// because a call app can change device without anything system-wide
    /// changing at all.
    func checkRoute() {
        guard isRecording, !restartPending else { return }
        if restartIfSilent() { return }
        guard let target = routeTarget(), target != boundDevice else { return }
        // Two questions a second apart: a route in the middle of changing
        // answers differently each time, and every move costs silence in the
        // track.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeSettle) { [weak self] in
            guard let self, self.isRecording, !self.restartPending else { return }
            guard let now = self.routeTarget(), now == target, now != self.boundDevice
            else { return }
            let report = "mic: microphone moved to \(AudioDevices.name(of: now) ?? "?") "
                + "(was \(AudioDevices.name(of: self.boundDevice) ?? "?")) — following it\n"
            FileHandle.standardError.write(Data(report.utf8))
            self.restartPending = true
            self.restartCapture()
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let engine { finalVoiceProcessing = engine.inputNode.isVoiceProcessingEnabled }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        stopListeningForDefaultInputChanges()
        stopEngine()
        stopRaw()
        // Nothing raw capture delivers from here on is written, however long
        // its device takes to stop. A buffer already past that check may be
        // writing, and is waited for.
        let writer = state.withLockUnchecked { s -> TrackWriter? in
            s.generation += 1
            return s.writer
        }
        ioQueue.sync {}
        // Whatever a gap left queued belongs in the file before it is let go,
        // and nothing more can be added to it now.
        writer?.drain()
        file = nil
        lastBufferAt = nil
        // Nothing will arrive to close an open gap now, and the track ends
        // where the audio ended.
        state.withLock { $0.log.abandon() }
        attachedReusingFile = false
        liveAudio.install(nil)
    }

    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {
        liveAudio.install(sink)
    }

    func setLiveAudioPaused(_ paused: Bool) {
        liveAudio.isPaused = paused
    }

    // MARK: - voice processing

    /// Build the voice-processing graph, create the PCM file if there is
    /// none, and start capture. Called at start when voice processing is
    /// asked for, and again by a restart that keeps it.
    ///
    /// `reusingFile` changes two things and nothing else: the client format
    /// follows the open file rather than the new device, and a failure here
    /// leaves that file alone.
    private func attachVoice(reusingFile: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        bindInputDevice(of: input)

        do {
            try input.setVoiceProcessingEnabled(true)
            // The live voice unit makes macOS treat the session like a call
            // and duck all other audio — meetings played through the speakers
            // would get quieter the moment recording starts.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            self.engine = nil
            throw RecorderError.voiceProcessingUnavailable(error)
        }
        // The unit's client side: it converts from the hardware by itself.
        let inputFormat = input.outputFormat(forBus: 0)
        inputChannels = Int(inputFormat.channelCount)

        // One explicit mono client format, the Voice I/O boundary format on
        // both sides of the duplex unit — never the inherited multichannel
        // route format (a 9-channel device yielded digital silence).
        //
        // Mid-session the rate is the open file's, not the new device's: the
        // device may well come back at another rate (48k speakers, 24k
        // AirPods) and the file's format is the one thing that cannot change.
        // The unit converts between its hardware and client scopes.
        let existing = reusingFile ? file : nil
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: existing?.processingFormat.sampleRate ?? inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            self.engine = nil
            throw RecorderError.formatUnsupported(inputFormat)
        }

        // Complete the duplex graph: VoiceProcessingIO must render to an
        // output device or the input side never produces audio. The mixer
        // has no sources — nothing is monitored or played — its connection
        // exists solely to give the unit a formatted output path.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
        livenessFrames = 0
        livenessPeak = 0
        livenessSettled = false
        do {
            try installVoiceTap(
                on: input, format: monoFormat, reusingFile: existing != nil,
                generation: state.withLock { $0.generation })
        } catch {
            self.engine = nil
            throw error
        }

        if existing == nil {
            do {
                file = try AVAudioFile(
                    forWriting: url!,
                    settings: AudioFormats.pcmSettings(
                        sampleRate: monoFormat.sampleRate, channels: 1
                    ),
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
            } catch {
                input.removeTap(onBus: 0)
                self.engine = nil
                throw RecorderError.fileCreationFailed(error)
            }
        }
        attachedReusingFile = existing != nil

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            if existing == nil { file = nil }
            // If we had pointed it at a microphone of our own choosing, that
            // is the first suspect: it is not asked again for a while, and the
            // retry gets the default instead.
            if boundChosenDevice, let boundDevice { refused.refuse(boundDevice, at: Date()) }
            throw RecorderError.engineStartFailed(error)
        }
        attachedAt = Date()
        finalVoiceProcessing = input.isVoiceProcessingEnabled
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDeadline) { [weak self] in
            self?.restartIfSilent()
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Stop the voice-processing engine, if that is what is capturing.
    private func stopEngine() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private static func name(of format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "float32"
        case .pcmFormatFloat64: return "float64"
        case .pcmFormatInt16: return "int16"
        case .pcmFormatInt32: return "int32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    ///
    /// Mid-session the window is longer, because there the check has a false
    /// positive it doesn't have at startup: the noise suppressor emits true
    /// digital zeros in a quiet room, in runs that have reached 0.9 s in a
    /// real meeting. Reading a lull as a dead route would drop echo
    /// cancellation for the rest of the call — the exact failure this restart
    /// path exists to prevent.
    private func installVoiceTap(
        on input: AVAudioInputNode, format: AVAudioFormat, reusingFile: Bool, generation: Int
    ) throws {
        let checkFrames = Int(format.sampleRate * (reusingFile ? 3 : 1))
        try Self.installTap(on: input, format: format) { [weak self] buffer, _ in
            guard let self, let writer = self.writer(for: generation) else { return }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw(from: generation) }
                        return
                    }
                }
            }

            self.writeTracked(buffer, to: writer, generation: generation)
        }
    }

    /// Write one captured buffer, recording its level on the way through and
    /// substituting silence while paused. Both paths funnel through here so
    /// the pause and the level tracking can't diverge between them.
    /// `skipped` is audio of the device's that went by unread just before
    /// this buffer, in the track's frames, written as silence to keep the
    /// track on the wall clock.
    private func writeTracked(
        _ buffer: AVAudioPCMBuffer, to writer: TrackWriter, generation: Int,
        skipped: AVAudioFrameCount = 0
    ) {
        guard let silence = pendingGap(
            before: buffer, rate: writer.file.processingFormat.sampleRate, generation: generation
        ) else { return }
        let peak = AudioLevel.peak(of: buffer)
        let muted: Bool = state.withLock { s in
            if let peak {
                if peak >= AudioLevel.speechThreshold { s.lastSoundAt = Date() }
            } else {
                s.levelMeasurable = false
            }
            return s.muted
        }

        var outgoing = buffer
        if muted {
            guard let silent = AudioLevel.silence(like: buffer) else { return }
            outgoing = silent
        }
        writer.write(outgoing, after: silence + skipped)
        liveAudio.forward(outgoing)
    }

    // MARK: - raw capture

    /// What a raw start tells main.
    private struct RawStart: Sendable {
        let device: AudioObjectID
        let channels: Int
        let reusedFile: Bool
        let report: String
    }

    /// Bring raw capture up off main. The work goes to `deviceQueue`, which
    /// first stops whatever raw capture ran before, and is reported back to
    /// `rawStarted` or `rawFailed`. There a microphone of our choosing that
    /// will not start gives way to the default, as in `attachWithFallbacks`,
    /// and is not asked again for a while. `index` is the restart this
    /// capture ends, when it is one.
    ///
    /// Throws only when there is no microphone to try.
    private func startRaw(restart index: Int?) throws {
        let fallback = AudioDevices.defaultInput()
        let wanted = routeTarget()
        let candidates = [wanted, wanted == fallback ? nil : fallback].compactMap { $0 }
        guard !candidates.isEmpty else { throw RecorderError.noMicrophone }
        let url = url!
        let generation = state.withLock { $0.generation }
        restartPending = true
        deviceQueue.async { [self] in
            openRaw(on: candidates, fallback: fallback, url: url, generation: generation, restart: index)
        }
    }

    /// On `deviceQueue`: stop the raw capture there is, and start one on the
    /// first of `candidates` that will.
    private func openRaw(
        on candidates: [AudioObjectID], fallback: AudioObjectID?, url: URL, generation: Int,
        restart index: Int?
    ) {
        proc?.stop()
        proc = nil
        var refusals: [AudioObjectID] = []
        var failed: [AudioObjectID] = []
        var failure = "\(RecorderError.noMicrophone)"
        for device in candidates {
            // Stopped, or overtaken by a newer attach, while this one waited.
            guard state.withLock({ $0.generation }) == generation else { return }
            do {
                let (opened, started) = try openProc(on: device, url: url, generation: generation)
                proc = opened
                let chosen = device != fallback
                let refused = refusals, tried = failed
                DispatchQueue.main.async { [self] in
                    rawStarted(
                        started, chosen: chosen, refusals: refused, failed: tried,
                        generation: generation, restart: index)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                failure = "\(error)"
                failed.append(device)
                // A microphone that has gone away has not refused anything.
                if device != fallback, MicIOProc.isAlive(device) { refusals.append(device) }
                FileHandle.standardError.write(Data(
                    "warning: cannot record \(AudioDevices.name(of: device) ?? "device \(device)") (\(error))\n".utf8))
            }
        }
        let refused = refusals
        let reason = failure
        DispatchQueue.main.async { [self] in
            rawFailed(reason, refusals: refused, generation: generation)
        }
    }

    /// On `deviceQueue`: open `device`, create the file if the session has
    /// none yet, and start the device writing to it.
    private func openProc(
        on device: AudioObjectID, url: URL, generation: Int
    ) throws -> (MicIOProc, RawStart) {
        let opened = try MicIOProc(device: device)
        let input = opened.format
        let (mono, converter, reusedFile) = try claimTrack(for: input, at: url, generation: generation)

        let gain = Self.rawGain(for: input)
        try opened.start(
            on: ioQueue,
            changed: { [weak self] in
                guard let self else { return }
                self.deviceQueue.async { self.checkDevice() }
            },
            body: { [weak self] buffer, missed in
                self?.writeRaw(
                    buffer, missed: missed, as: mono, converter: converter, gain: gain,
                    generation: generation)
            })
        let report = "mic: voiceProcessing=false device=\(AudioDevices.name(of: device) ?? "?") "
            + "input=\(input) track=\(mono)\n"
        return (opened, RawStart(
            device: device, channels: Int(input.channelCount), reusedFile: reusedFile,
            report: report))
    }

    /// The track a raw capture of `input` writes, and the converter into it:
    /// the session's open file, or one created now. Settled in the same lock
    /// in which a stop or a restart retires a capture, so one retired while
    /// its device opened gets neither and throws `CancellationError`. Looked
    /// at apart from that check, the file could already have been let go by
    /// a stop: the open created it again, over the meeting in it, and then
    /// deleted it as a file nobody wanted.
    func claimTrack(
        for input: AVAudioFormat, at url: URL, generation: Int
    ) throws -> (mono: AVAudioFormat, converter: AVAudioConverter, reusedFile: Bool) {
        try state.withLockUnchecked { s in
            guard s.generation == generation else { throw CancellationError() }
            // Mid-session the rate is the open file's, not the device's: the
            // device may well come back at another rate (48k built-in, 24k
            // AirPods) and the file's format is the one thing that cannot
            // change. `convertResampling` makes up the difference.
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: s.file?.processingFormat.sampleRate ?? input.sampleRate,
                channels: 1,
                interleaved: false
            ), let converter = Self.monoConverter(from: input, to: mono)
            else { throw RecorderError.formatUnsupported(input) }
            if s.file != nil { return (mono, converter, true) }
            do {
                let created = try AVAudioFile(
                    forWriting: url,
                    settings: AudioFormats.pcmSettings(sampleRate: mono.sampleRate, channels: 1),
                    commonFormat: mono.commonFormat,
                    interleaved: mono.isInterleaved)
                s.file = created
                s.writer = TrackWriter(file: created, label: "mic")
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
            return (mono, converter, false)
        }
    }

    /// One buffer of raw capture, on `ioQueue`: the device's first channel,
    /// at the file's rate, louder where it is a bare capsule (`rawGain`),
    /// after silence for the device's frames that were `missed` before it.
    private func writeRaw(
        _ buffer: AVAudioPCMBuffer, missed: AVAudioFrameCount, as mono: AVAudioFormat,
        converter: AVAudioConverter, gain: Float, generation: Int
    ) {
        guard let writer = writer(for: generation) else { return }
        let ratio = mono.sampleRate / buffer.format.sampleRate
        guard let track = AVAudioPCMBuffer(
            pcmFormat: mono,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        ) else { return }
        do {
            if ratio == 1 {
                try converter.convert(to: track, from: buffer)
            } else {
                // The device came back at another rate than the file's, and
                // the one-shot convert only handles equal rates.
                try Self.convertResampling(buffer, to: track, using: converter)
            }
        } catch {
            FileHandle.standardError.write(Data("mic downmix failed: \(error)\n".utf8))
            return
        }
        Self.amplify(track, by: gain)
        writeTracked(
            track, to: writer, generation: generation,
            skipped: AVAudioFrameCount(Double(missed) * ratio))
    }

    /// Raw capture is up. What main keeps about the capture is brought up to
    /// date here, for the raw path, and nowhere else.
    private func rawStarted(
        _ started: RawStart, chosen: Bool, refusals: [AudioObjectID], failed: [AudioObjectID],
        generation: Int, restart index: Int?
    ) {
        for device in refusals { refused.refuse(device, at: Date()) }
        // Overtaken by a newer attach, or stopped: theirs is the report that
        // counts.
        guard isRecording, state.withLock({ $0.generation }) == generation else { return }
        restartPending = false
        rawRunning = true
        boundDevice = started.device
        boundChosenDevice = chosen
        attachedAt = Date()
        attachedReusingFile = started.reusedFile
        inputChannels = started.channels
        finalVoiceProcessing = false
        if chosen {
            FileHandle.standardError.write(Data(
                "mic: recording \(AudioDevices.name(of: started.device) ?? "?"), the microphone the call is on\n".utf8
            ))
        }
        FileHandle.standardError.write(Data(started.report.utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDeadline) { [weak self] in
            self?.restartIfSilent()
        }
        if let index { noteRestart(index) }
        noteStarted()
        // Every route check while the device started was held off by
        // `restartPending`, so a microphone the call moved to meanwhile has
        // not been followed yet. One that has just failed to open is left to
        // the next tick, as it always was: one on its way out fails again at
        // once, and every try costs the track a restart.
        if let target = routeTarget(), !failed.contains(target) { checkRoute() }
    }

    /// No microphone would start. Asked again in two seconds, as a failed
    /// restart always has been.
    private func rawFailed(_ reason: String, refusals: [AudioObjectID], generation: Int) {
        for device in refusals { refused.refuse(device, at: Date()) }
        guard isRecording, state.withLock({ $0.generation }) == generation else { return }
        restartPending = false
        FileHandle.standardError.write(Data(
            "mic: capture would not start: \(reason) — retrying in 2s\n".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isRecording, !self.restartPending else { return }
            self.restartCapture()
        }
    }

    /// On `deviceQueue`: whether raw capture still has the device it was
    /// opened on, in the shape it was opened in. Asked on every change the
    /// device reports, and on every buffer of a shape the proc was not opened
    /// for; only a no goes to main, which rebuilds.
    private func checkDevice() {
        guard let proc else { return }
        let device = proc.device
        // Taken before the device is looked at, so that an alarm raised while
        // it is being looked at is not lifted by what was seen.
        let alarms = proc.alarms
        let gone = !MicIOProc.isAlive(device)
        if !gone, MicIOProc.format(of: device)?.isEqual(proc.format) == true {
            proc.trust(asOf: alarms)
            return
        }
        DispatchQueue.main.async { [self] in deviceChanged(device, gone: gone) }
    }

    /// The microphone under raw capture went away, or changed shape. Rebuilt
    /// at once for a new shape, whose buffers cannot be read as the old one,
    /// and after a moment for a device that went away, so that the route has
    /// settled on whatever replaces it.
    private func deviceChanged(_ device: AudioObjectID, gone: Bool) {
        guard isRecording, !restartPending, rawRunning, device == boundDevice else { return }
        FileHandle.standardError.write(Data(
            "mic: \(inputDevice ?? "the microphone") \(gone ? "went away" : "changed format") — restarting capture\n".utf8
        ))
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (gone ? 0.5 : 0)) { [weak self] in
            self?.restartCapture()
        }
    }

    /// Retire raw capture, if that is what is capturing. Its device stops on
    /// `deviceQueue`, after whatever is already queued there.
    private func stopRaw() {
        rawRunning = false
        deviceQueue.async { [self] in
            proc?.stop()
            proc = nil
        }
    }

    // MARK: -

    /// A converter from the device's own format to the mono track that reads
    /// the device's first channel.
    ///
    /// Said outright because the converter's own choice is silence whenever
    /// the input's channels carry no position it can match to mono. The
    /// built-in microphone becomes three such channels while another process
    /// runs Apple's voice processing on it — `avconferenced`, for a call
    /// handed over from the iPhone — and the default map is then `[-1]`:
    /// every buffer converts to digital zeros, without an error. On 30
    /// September 2026 that left a nine-minute call with only the far end in
    /// it. Mono and stereo inputs map to channel 0 by default anyway.
    static func monoConverter(from input: AVAudioFormat, to mono: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: input, to: mono)
        converter?.channelMap = [0]
        return converter
    }

    /// How much louder the raw path writes what it reads: ten times, +20 dB,
    /// for the three-channel shape, and as it comes otherwise.
    ///
    /// Those three channels are the built-in microphone's capsules before the
    /// beamforming and gain that make its ordinary one-channel stream. The
    /// process that asked for them does both for itself — `avconferenced`
    /// logs a 36.5 dB input gain — and nothing does either for us, so channel
    /// 0 alone sits about 20 dB under the ordinary stream. On 30 September
    /// 2026 one call's mic floor rose that much at the restart where the call
    /// left `avconferenced`, and our side of four such calls sat at −54 to
    /// −56 dBFS against −30 in a browser call. The far end, which a bare
    /// capsule hears as well as it hears us, comes up with it: level with our
    /// voice, and over `SpeakerAttribution`'s speech floor.
    ///
    /// ponytail: recognised by channel count, with one fixed gain, both
    /// measured on one MacBook Air (M1). If another Mac's capsule clips or
    /// stays quiet, the upgrade is a gain per model.
    static func rawGain(for input: AVAudioFormat) -> Float {
        input.channelCount == 3 ? 10 : 1
    }

    /// Multiply the track's samples by `gain`, held to full scale.
    static func amplify(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard gain != 1, let samples = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) { samples[i] = min(1, max(-1, samples[i] * gain)) }
    }

    /// Tap bus 0 of `input`, with a format AVFAudio refuses thrown rather
    /// than raised.
    ///
    /// The old call reports a refusal with an Objective-C exception, which
    /// Swift cannot catch: the app ends there, the system track with it.
    /// From macOS 27 the same refusal comes back as an error, and the start
    /// and the restart already know what to do with one. Before 27 there is
    /// no such call, and a refused tap is still fatal.
    static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock
    ) throws {
        if #available(macOS 27, *) {
            try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: (), block: block)
        } else {
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: block)
        }
    }

    /// Feed `buffer` through `converter` exactly once, for the rate-mismatched
    /// case the one-shot `convert(to:from:)` can't handle.
    ///
    /// The "have I fed it yet" flag lives in a box rather than a local `var`:
    /// `AVAudioConverterInputBlock` is typed `@Sendable`, so Swift 6 rejects
    /// capturing a mutable local even though `convert` invokes the block
    /// synchronously on this very thread before returning.
    private static func convertResampling(
        _ buffer: AVAudioPCMBuffer,
        to mono: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) throws {
        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var convertError: NSError?
        converter.convert(to: mono, error: &convertError) { _, outStatus in
            if feed.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let convertError { throw convertError }
    }

    /// Point this engine at the microphone we mean to record.
    ///
    /// Only when that is not the default one: an engine picks the default up
    /// by itself at start, so following a default that changed needs nothing
    /// but the restart. What needs saying out loud is the other case — the
    /// call app listening to a microphone the system has not been told about —
    /// and that is the only case where this touches the unit at all, which
    /// keeps a device the voice unit dislikes out of the ordinary path.
    ///
    /// A refusal is not fatal. Capture continues on the default, which is
    /// where it would have been anyway; it is logged because it means the
    /// track and the call are listening to different microphones.
    private func bindInputDevice(of input: AVAudioInputNode) {
        let fallback = AudioDevices.defaultInput()
        boundChosenDevice = false
        guard let wanted = routeTarget(), wanted != fallback else {
            boundDevice = fallback
            return
        }
        let name = AudioDevices.name(of: wanted) ?? "?"
        do {
            try input.auAudioUnit.setDeviceID(wanted)
            boundDevice = wanted
            boundChosenDevice = true
            FileHandle.standardError.write(Data(
                "mic: recording \(name), the microphone the call is on\n".utf8
            ))
        } catch {
            boundDevice = fallback
            refused.refuse(wanted, at: Date())
            FileHandle.standardError.write(Data(
                "warning: cannot record \(name) (\(error)) — using the default mic\n".utf8
            ))
        }
    }

    /// The microphone capture should be bound to now, refusals considered.
    private func routeTarget() -> AudioObjectID? {
        Self.routeTarget(
            wanted: MicRoute.preferred(callApps: followedCallApps)?.id,
            fallback: AudioDevices.defaultInput(),
            refused: refused,
            now: Date())
    }

    /// `attachVoice` or `startRaw`, with the retreats of
    /// `MicRecorder.attachWithFallbacks`. Raw capture comes up off main, so
    /// for it this only sets the attempt going; its own retreat, from a
    /// chosen microphone to the default, happens on `deviceQueue`.
    private func attachWithFallbacks(
        voiceProcessing: Bool, reusingFile: Bool, restart index: Int? = nil
    ) throws {
        try Self.attachWithFallbacks(
            voiceProcessing: voiceProcessing,
            attempt: { voice in
                do {
                    if voice {
                        try attachVoice(reusingFile: reusingFile)
                    } else {
                        try startRaw(restart: index)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "mic: capture would not start (voiceProcessing=\(voice)): \(error)\n".utf8))
                    throw error
                }
            },
            // The same attempt again lands on the default only when the chosen
            // microphone refused; anything else would fail the same way twice.
            failedOnChosenDevice: {
                boundChosenDevice && boundDevice.map { refused.isRefused($0, at: Date()) } == true
            })
    }

    /// Follow the system default input while recording. A default that changes
    /// under running capture is silent in every other way — capture stays on
    /// the device it was opened on, and nothing is posted — so without this
    /// listener, choosing another microphone mid-meeting leaves amanu
    /// recording the old one for the rest of the call.
    private func listenForDefaultInputChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.checkRoute() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if status == noErr {
            defaultInputListener = listener
        } else {
            let warning = "warning: cannot watch the default microphone (\(status)) — "
                + "a mid-meeting change will not be followed\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private func stopListeningForDefaultInputChanges() {
        guard let defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main,
            defaultInputListener
        )
        self.defaultInputListener = nil
    }

    /// Another process reconfigured the input device (typically a call app
    /// engaging voice processing) and the voice engine stopped. Debounce
    /// briefly — reconfiguration storms post several notifications — then
    /// restart.
    private func handleConfigChange() {
        guard isRecording, !restartPending else { return }
        restartPending = true

        if Date().timeIntervalSince(attachedAt) <= Self.settleWindow, engine?.isRunning == true {
            // Possibly our own attach reconfiguring the device — but only
            // possibly, and only while the engine is still running. An engine
            // that has stopped never restarts itself, so there is nothing to
            // wait for and the case falls through to the restart below.
            //
            // Otherwise wait for the new engine to prove itself rather than
            // guessing whose change this is: buffers still arriving at the
            // deadline means it is alive and the change was ours, and no
            // buffers means it stopped and has to be rebuilt whoever caused it.
            let wait = max(attachedAt.addingTimeInterval(Self.settleDeadline).timeIntervalSinceNow, 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.isRecording else { return }
                if self.audioIsFlowing {
                    self.restartPending = false
                    FileHandle.standardError.write(Data(
                        "mic: configuration change was our own — capture is alive\n".utf8
                    ))
                    return
                }
                FileHandle.standardError.write(Data(
                    "mic: no audio after the engine was reconfigured — restarting capture\n".utf8
                ))
                self.restartCapture()
            }
            return
        }

        FileHandle.standardError.write(Data(
            "mic: input device reconfigured (call app?) — restarting capture\n".utf8
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartCapture()
        }
    }

    /// Whether a buffer has landed since the current capture attached,
    /// recently enough to call it alive. The only evidence that separates a
    /// device we reconfigured ourselves from one that stopped.
    ///
    /// Both halves matter. A buffer from the capture that has just been torn
    /// down says nothing about the one that replaced it, and without the first
    /// half dead capture looks alive for a whole second after every restart.
    private var audioIsFlowing: Bool {
        guard let last = lastBufferAt, last > attachedAt else { return false }
        return Date().timeIntervalSince(last) < Self.aliveWithin
    }

    /// Rebuild capture if it is running and nothing has come out of it for
    /// `settleDeadline`. Asked after every attach, and on every route check
    /// for capture that stops delivering later.
    ///
    /// Nothing else would notice: such capture raises no error and posts no
    /// configuration change. On 2 October 2026 a restart while AirPods were
    /// changing mode left an engine running with Core Audio dropping every
    /// cycle of the built-in microphone ("mono buffer too small (512 > 480)")
    /// until something else restarted it 74 seconds later. A tap AVFAudio
    /// refuses without saying so ("config change pending") looks the same
    /// from here, and so would an IO proc its device stopped calling.
    @discardableResult
    private func restartIfSilent() -> Bool {
        guard isRecording, !restartPending, Self.isSilent(
            lastBufferAt: lastBufferAt, since: attachedAt, running: engine?.isRunning ?? rawRunning,
            now: Date())
        else { return false }
        FileHandle.standardError.write(Data(
            "mic: no audio for \(Int(Self.settleDeadline))s from running capture — restarting it\n".utf8))
        restartCapture()
        return true
    }

    /// Whether running capture has gone `settleDeadline` without a buffer,
    /// counted from its attach when it has delivered none — a buffer from
    /// before then came from the capture it replaced.
    static func isSilent(lastBufferAt: Date?, since attachedAt: Date, running: Bool, now: Date) -> Bool {
        guard running else { return false }
        let last = max(lastBufferAt ?? attachedAt, attachedAt)
        return now.timeIntervalSince(last) >= settleDeadline
    }

    /// Rebuild capture on the new route, keeping the file, the wall clock,
    /// and — the part this used to give away — echo cancellation.
    ///
    /// Restarting raw was justified by "during a call the call app owns echo
    /// cancellation", which is true of what Zoom sends and says nothing about
    /// what we capture. amanu taps the device itself, so dropping voice
    /// processing means the mic writes down whatever the speakers are playing.
    /// On 2026.08.20 that turned the far end into a second voice on our own
    /// track, 3 dB under the real one, for the 35 minutes between an AirPods
    /// route change and the end of the call.
    private func restartCapture() {
        restartPending = false
        guard isRecording else { return }
        stopEngine()
        stopRaw()
        // The gap is only marked here, not written: the first buffer of the
        // new capture is the only thing that knows how long the dead span
        // really was. Starting a device takes a few hundred milliseconds, and
        // padding before the start left every one of them out of the track —
        // two restarts put the mic 0.75 s ahead of the system track, far
        // enough for its echo of the far end to precede the far end.
        let (index, recent) = retireCapture(at: Date())
        let storming = recent >= Self.stormLimit
        if storming {
            FileHandle.standardError.write(Data(
                "warning: \(recent) mic restarts in \(Int(Self.stormWindow))s — capturing raw\n".utf8
            ))
        }
        let voice = Config.micVoiceProcessing() && !storming
        do {
            // The new route may be one the voice unit can't take (rca-001), or
            // the call app's microphone may refuse us; each gives way in turn.
            try attachWithFallbacks(voiceProcessing: voice, reusingFile: true, restart: index)
        } catch {
            FileHandle.standardError.write(Data("mic: retrying restart in 2s\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRecording else { return }
                self.restartCapture()
            }
            return
        }
        // Raw capture notes the restart, and the start, once its device has
        // started. Voice capture is up by now, and may be the first capture
        // of the session to come up at all: until it is noted as started, no
        // restart after it would open a gap.
        if engine != nil {
            if let index { noteRestart(index) }
            noteStarted()
        }
    }

    /// Retire the capture that is going — nothing it still delivers is
    /// written from here on — and open the gap that the first buffer of the
    /// next one closes. Returns that restart's place in the log, and how many
    /// others began within the storm window. Before capture has come up, or
    /// written anything, there is no restart to log: a retry of the start is
    /// not a route change, and nothing has been recorded to measure a gap
    /// from.
    func retireCapture(at now: Date) -> (index: Int?, recent: Int) {
        let started = startedOnce
        return state.withLock { s in
            s.generation += 1
            guard started || s.lastBufferAt != nil else { return (nil, 0) }
            let index = s.log.open(at: now, lastBufferAt: s.lastBufferAt)
            return (index, s.log.recent(within: Self.stormWindow, of: now))
        }
    }

    /// Capture is up for the first time this session: what it came up as is
    /// what `capture` reports for the start.
    private func noteStarted() {
        guard !startedOnce else { return }
        startedOnce = true
        inputDevice = AudioDevices.name(of: boundDevice) ?? AudioDevices.defaultInputName()
        outputDevice = AudioDevices.defaultOutputName()
        initialVoiceProcessing = finalVoiceProcessing
        initialInputDevice = inputDevice
        initialOutputDevice = outputDevice
        initialInputChannels = inputChannels
        if let format = file?.processingFormat {
            captureSampleRate = format.sampleRate
            captureChannels = Int(format.channelCount)
            captureSampleFormat = Self.name(of: format.commonFormat)
        }
    }

    /// Record what the route changed into, for meta.json and the run log.
    /// `gap_ms` is filled in by the first buffer, whenever that lands.
    private func noteRestart(_ index: Int) {
        // The microphone we are on, which is not always the default one —
        // that is the whole point of binding it.
        let input = AudioDevices.name(of: boundDevice) ?? AudioDevices.defaultInputName()
        let output = AudioDevices.defaultOutputName()
        let voice = engine?.inputNode.isVoiceProcessingEnabled ?? false
        let (inputWas, outputWas) = (inputDevice, outputDevice)
        let channels = inputChannels
        state.withLock {
            $0.log.update(index) { restart in
                restart.voiceProcessing = voice
                restart.inputChannels = channels
                restart.inputWas = inputWas
                restart.inputNow = input
                restart.outputWas = outputWas
                restart.outputNow = output
            }
        }
        let report = "mic: capture restarted — in \(inputDevice ?? "?") → \(input ?? "?"), "
            + "out \(outputDevice ?? "?") → \(output ?? "?"), voiceProcessing=\(voice)\n"
        FileHandle.standardError.write(Data(report.utf8))
        inputDevice = input
        outputDevice = output
    }

    /// Close an open gap ahead of the first buffer that follows it: the
    /// frames of silence for the span between the last buffer of the old
    /// capture and the start of the audio this one carries, so the track
    /// keeps its place on the wall clock. The writer puts them in the file
    /// off this thread.
    ///
    /// Nil when the capture `buffer` came from has been retired: such a
    /// buffer is not written at all, and decided in the same lock that would
    /// close the gap, so it cannot close the one opened for its successor.
    /// The buffer times are kept here too, for buffers that are written and
    /// no others: stamped before this check, a buffer a restart retired in
    /// between would move the start of its gap past audio never written.
    private func pendingGap(
        before buffer: AVAudioPCMBuffer, rate: Double, generation: Int
    ) -> AVAudioFrameCount? {
        let carried = Double(buffer.frameLength) / buffer.format.sampleRate
        return state.withLock { s -> AVAudioFrameCount? in
            guard s.generation == generation else { return nil }
            let now = Date()
            if s.firstBufferAt == nil { s.firstBufferAt = now }
            s.lastBufferAt = now
            let index = s.log.openIndex
            guard let gap = s.log.close(now: now, carried: carried) else { return 0 }
            let padded = min(gap, Self.longestPad)
            if padded < gap, let index { s.log.notePadded(padded, forEntry: index) }
            return Self.silenceFrames(gap: padded, sampleRate: rate)
        }
    }

    /// Frames of silence a dead span of `gap` seconds is worth. Spans under
    /// 50 ms are left alone: buffer timing and the wall clock disagree by
    /// about that much anyway, and padding the disagreement would drift the
    /// track as surely as ignoring a real gap.
    static func silenceFrames(gap: TimeInterval, sampleRate: Double) -> AVAudioFrameCount {
        guard gap > 0.05, sampleRate > 0 else { return 0 }
        return AVAudioFrameCount(gap * sampleRate)
    }

    /// The voice-processing route delivered digital silence: tear the engine
    /// down and restart raw, discarding the silent prefix so the track's
    /// timestamps start at real audio.
    private func fallBackToRaw(from generation: Int) {
        // Only for the engine that found it: a restart may have replaced that
        // engine since, or be replacing it now.
        guard isRecording, !restartPending, engine != nil,
              state.withLock({ $0.generation }) == generation
        else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        stopEngine()

        if attachedReusingFile {
            // Mid-session the "silent prefix" is a meeting. Keep the file and
            // the wall clock; give up only the cancellation.
            let (index, _) = retireCapture(at: Date())
            do {
                try startRaw(restart: index)
            } catch {
                FileHandle.standardError.write(Data(
                    "mic raw fallback failed: \(error) — retrying in 2s\n".utf8
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.restartCapture()
                }
            }
            return
        }

        // The engine goes with its file: nothing it still delivers is
        // written, and no gap is measured from its last buffer, or the new
        // file would open with that much silence ahead of a start time that
        // is its first raw buffer's.
        state.withLockUnchecked { s in
            s.generation += 1
            s.file = nil
            s.writer = nil
            s.firstBufferAt = nil
            s.lastBufferAt = nil
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attachWithFallbacks(voiceProcessing: false, reusingFile: false)
        } catch {
            // The watchdog reports a track with no file as stalled, so this
            // reaches the person as well as the log.
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
