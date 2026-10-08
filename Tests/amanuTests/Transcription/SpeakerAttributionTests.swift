import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Attribution and mixing are pure functions over audio files, so they're
/// testable without a meeting: synthesize two tracks with known speech
/// windows, then assert who each utterance gets credited to.
struct SpeakerAttributionTests {
    /// An AAC-in-CAF track shaped like MicRecorder/SystemAudioRecorder write:
    /// `bursts` are (start, end) seconds of tone, everything else silence.
    private static func writeTrack(
        to url: URL,
        seconds: Double,
        bursts: [(Double, Double)],
        gain: Float,
        rate: Double = 48000.0
    ) throws {
        try writeTrack(to: url, seconds: seconds, sources: [(bursts, gain)], rate: rate)
    }

    /// The same with several sources on one track, each at its own gain and
    /// summed where they overlap — our voice and the far end's echo on one mic.
    private static func writeTrack(
        to url: URL,
        seconds: Double,
        sources: [(bursts: [(Double, Double)], gain: Float)],
        rate: Double = 48000.0
    ) throws {
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ]
        try TestAudio.write(to: url, seconds: seconds, sampleRate: rate, settings: aac) { _, frame in
            let t = Double(frame) / rate
            let gain = sources.reduce(Float(0)) { sum, source in
                source.bursts.contains { t >= $0.0 && t < $0.1 } ? sum + source.gain : sum
            }
            return gain * Float(sin(2 * .pi * 220 * t))
        }
    }

    /// A 16 kHz PCM track shaped exactly like OfflineEchoAudio's output.
    private static func writeEchoCancelledTrack(to url: URL, seconds: Double) throws {
        try TestAudio.writeTone(
            to: url, seconds: seconds, frequency: 220, amplitude: 0.1, sampleRate: 16_000)
    }

    /// mic speaks 0–2s and 6–8s; system speaks 2.5–4.5s in its own timeline
    /// and starts 0.5s late, so on the shared clock it lands at 3.0–5.0s.
    /// Gains differ ~9x on purpose — two real tracks never match levels.
    private final class Fixture {
        let dir: URL
        let mic: URL
        let system: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("amanu-attr-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            mic = dir.appendingPathComponent("mic.caf")
            system = dir.appendingPathComponent("system.caf")
            try SpeakerAttributionTests.writeTrack(
                to: mic, seconds: 10, bursts: [(0, 2), (6, 8)], gain: 0.08)
            try SpeakerAttributionTests.writeTrack(
                to: system, seconds: 10, bursts: [(2.5, 4.5)], gain: 0.7)
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        func resolve(_ segments: [TranscriptSegment]) -> [String]? {
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0.5)
        }
    }

    private static func seg(
        _ start: Double, _ end: Double, _ speaker: String?
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "…", speaker: speaker)
    }

    @Test("Two diarization labels are split by which track was loud")
    func twoLabelsSplitByTrack() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 4.9, "B"), Self.seg(6.1, 7.9, "A")])
                == ["me", "them", "me"])
    }

    /// The bug that stopped speaker naming working at all. A room mic hears
    /// the far end coming out of the speakers, so a minority of one person's
    /// utterances reads as louder on mic.caf; deciding the side per utterance
    /// turned that person into two speakers, and the naming pass then dutifully
    /// put the same name on both. On the real sessions of 18 August this
    /// happened to every voice in every meeting — `2026.08.18-1502` came out of
    /// two speakers as four labels, and `-1303` out of six as twelve.
    ///
    /// Here A is loud on the system track twice and on the mic once, which is
    /// exactly that shape, and it has to stay one speaker.
    @Test("A voice that leaks into the other track is still one speaker")
    func leakageDoesNotSplitAVoice() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 3.9, "A"), Self.seg(4.0, 4.9, "A")])
                == ["them", "them", "them"])
    }

    /// The invariant the naming pass rests on, stated on its own: whatever the
    /// tracks say utterance by utterance, a diarization label comes back as one
    /// name. Two names for one voice is two people as far as `speakers.json` is
    /// concerned, and no amount of evidence in the transcript can tell them
    /// apart afterwards, because there is nothing there to tell apart.
    @Test("One diarized voice never becomes two speakers")
    func aVoiceKeepsOneName() throws {
        let f = try Fixture()
        // A talks on the mic and leaks once into the far track; B does the
        // reverse. Both come back as one name each, on opposite sides.
        let segments = [
            Self.seg(0.1, 1.0, "A"), Self.seg(1.1, 1.9, "A"), Self.seg(3.1, 3.5, "A"),
            Self.seg(3.6, 4.0, "B"), Self.seg(4.1, 4.9, "B"), Self.seg(6.1, 7.9, "B"),
        ]
        let resolved = try #require(f.resolve(segments))
        var namesPerVoice: [String: Set<String>] = [:]
        for (segment, name) in zip(segments, resolved) {
            namesPerVoice[segment.speaker!, default: []].insert(name)
        }
        #expect(namesPerVoice.mapValues(\.count) == ["A": 1, "B": 1])
    }

    @Test("Segments with no diarization label still get a side")
    func unlabelledSegmentsGetASide() throws {
        let f = try Fixture()
        #expect(f.resolve([Self.seg(0.1, 1.9, nil), Self.seg(3.1, 4.9, nil)]) == ["me", "them"])
    }

    /// Several people sharing the far-side channel is the thing only
    /// diarization can resolve, so labels survive as suffixes there — but the
    /// lone mic speaker stays plain "me" rather than "me A".
    @Test("Multiple far-side speakers keep their labels as suffixes")
    func farSideSpeakersKeepLabels() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 3.9, "B"), Self.seg(4.0, 4.9, "C")])
                == ["me", "them A", "them B"])
    }

    @Test("A one-sided recording is a legitimate all-me answer")
    func oneSidedRecording() throws {
        let f = try Fixture()
        #expect(f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(6.1, 7.9, "A")]) == ["me", "me"])
    }

    /// Catches treating a stereo archive as two identical downmixed files,
    /// which credits every utterance to the same side after PCM is removed.
    @Test("Speaker attribution reads archive channels independently")
    func archivedChannelsStayIndependent() throws {
        let f = try Fixture()
        try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 500],
        ]).write(to: f.dir.appendingPathComponent("meta.json"), options: .atomic)
        TrackCompressor.compress(sessionDir: f.dir)

        let archive = f.dir.appendingPathComponent("audio.m4a")
        let segments = [Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 4.9, "B")]
        #expect(SpeakerAttribution.resolve(
            segments: segments,
            mic: archive,
            micOffset: 0,
            system: archive,
            systemOffset: 0
        ) == ["me", "them"])
    }

    @Test("A stretch silent on both tracks inherits its label's usual side")
    func silentStretchInheritsSide() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(8.2, 9.4, "A"), Self.seg(3.1, 4.9, "B")])
                == ["me", "me", "them"])
    }

    /// The failure this floor exists for, measured on a real session: the far
    /// end spoke on the system track, the mic carried nothing but room noise,
    /// and per-track normalization made that noise look exactly like speech —
    /// every utterance came back credited to "me".
    ///
    /// The mechanism is worth stating, because it is not obvious: normalizing
    /// against a track's own p90 means a *uniform* track (noise) always reads
    /// at ~1.0, while a track carrying real speech reads below its own p90
    /// wherever the speaker pauses. So noise beats speech whenever the
    /// utterance window contains a breath.
    @Test("A track holding only room noise loses to the one holding speech")
    func noiseOnlyTrackLosesToSpeech() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-noise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noisy = dir.appendingPathComponent("mic.caf")
        let speech = dir.appendingPathComponent("system.caf")
        // An open mic in a quiet room: continuous, featureless, about −60 dBFS.
        try Self.writeTrack(to: noisy, seconds: 10, bursts: [(0, 10)], gain: 0.001)
        // The far end talking, with a pause where someone drew breath.
        try Self.writeTrack(to: speech, seconds: 10, bursts: [(3, 4), (4.5, 5)], gain: 0.7)

        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(3.0, 5.0, "A")],
                mic: noisy, micOffset: 0, system: speech, systemOffset: 0) == ["them"])
    }

    @Test("A missing track refuses to attribute rather than guessing")
    func missingTrackRefuses() throws {
        let f = try Fixture()
        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(0.1, 1.9, "A")],
                mic: f.dir.appendingPathComponent("nope.caf"), micOffset: 0,
                system: f.system, systemOffset: 0.5) == nil)
    }

    /// A mic that recorded nothing is still an answer, because the mix is only
    /// ever the two tracks: whatever the engine heard came in through the
    /// system one. On 30 September 2026 the mic went dead on a route change
    /// for a whole call, and refusing here left the far end as "spk:0".
    ///
    /// That holds where the far end was silent too. An utterance under
    /// nothing at all did not come in through a mic that heard nothing.
    @Test("A silent mic puts every voice on the far side")
    func silentMicMeansTheFarSide() throws {
        let f = try Fixture()
        let silent = f.dir.appendingPathComponent("silent.caf")
        try Self.writeTrack(to: silent, seconds: 10, bursts: [], gain: 0)
        #expect(
            SpeakerAttribution.resolve(
                segments: [
                    Self.seg(3.1, 4.9, "A"), Self.seg(6.1, 7.9, "A"), Self.seg(8.2, 9.4, "A"),
                ],
                mic: silent, micOffset: 0, system: f.system, systemOffset: 0.5)
                == ["them", "them", "them"])
    }

    /// A FaceTime call as its tracks record it: us at about −55 dBFS on the
    /// mic, under the speech floor, and the far end at about −23 on its own
    /// track, which is silent while we talk.
    private static func faceTimeCall(
        us: [(Double, Double)], farEnd: [(Double, Double)], _ segments: [TranscriptSegment]
    ) throws -> [String]? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-facetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try writeTrack(to: mic, seconds: 10, bursts: us, gain: 0.0025)
        try writeTrack(to: system, seconds: 10, bursts: farEnd, gain: 0.1)
        return SpeakerAttribution.resolve(
            segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
    }

    /// The mix is only ever the two tracks, so an utterance the far end said
    /// nothing over came in through the mic, however quietly the mic heard
    /// it. On 1 October 2026 (`2026.10.01-1323`) our voice read −54 to
    /// −62 dBFS on the mic: of nine utterances, five cleared the floor on
    /// neither track and went undecided, one read as ours, and the three the
    /// far end spoke over read as theirs and put the whole voice on its side.
    @Test("Our voice under the speech floor is still ours while the far end is silent")
    func quietMicWhileTheFarEndIsSilent() throws {
        let names = try Self.faceTimeCall(
            us: [(0, 1.5), (6, 8), (8.5, 9.5)], farEnd: [(2, 5), (7, 7.4)],
            [
                Self.seg(0.1, 1.4, "A"), Self.seg(2.1, 4.9, "B"),
                Self.seg(6.1, 7.9, "A"), Self.seg(8.6, 9.4, "A"),
            ])
        #expect(names == ["me", "them", "me", "me"])
    }

    /// An utterance the far end spoke over only part of reads as theirs when
    /// the mic heard us under the floor, and a voice that answered over them
    /// more often than it spoke alone was outvoted onto their side. The far
    /// end's own utterances are the ones its track fills: on three calls of
    /// 30 September and 1 October 2026 the system track held speech for 85–94%
    /// of a far-end utterance, by the median, and for 1–40% of each of ours
    /// that it spoke over.
    @Test("The far end speaking over part of an utterance does not outvote the rest")
    func talkingOverUsDoesNotOutvoteUs() throws {
        let names = try Self.faceTimeCall(
            us: [(0, 1.5), (6, 7.5), (8, 9.5)], farEnd: [(2, 5), (6.5, 6.8), (9, 9.3)],
            [
                Self.seg(0.1, 1.4, "A"), Self.seg(2.1, 4.9, "B"),
                Self.seg(6.1, 7.4, "A"), Self.seg(8.1, 9.4, "A"),
            ])
        #expect(names == ["me", "them", "me", "me"])
    }

    /// A call on the speakers, as the MacBook's own mic hears it: the far end
    /// comes back 150 ms late, rings on for a few hundred more, and reads
    /// louder there than we do. Normalized against its own p90, which is now
    /// the echo, the mic reads as loud as the far end's own track over every
    /// far-end utterance, and the room's ring tips each one to us. On 7
    /// October 2026 (`2026.10.07-1540`) that put the whole far end on "me".
    ///
    /// The system track starts a second late, so an echo looked for on the
    /// wrong side of that offset finds the far end silent and passes for us.
    /// And the far end is once 14 dB louder than the rest, as in that call,
    /// which must not be what says how loud its echo runs.
    @Test("The far end on the speakers stays the far end where its echo outshouts us")
    func farEndEchoOnTheSpeakersStaysTheFarEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-echo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let farEnd = (0..<6).map { (2 + 4 * Double($0), 3.5 + 4 * Double($0)) }
        let loud = [(6.5, 6.9)]
        let us = [(4.0, 5.5), (12.0, 13.5), (20.0, 21.5)]
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        let echo = { (bursts: [(Double, Double)]) in bursts.map { ($0.0 + 0.15, $0.1 + 0.45) } }
        try Self.writeTrack(
            to: mic, seconds: 25, sources: [(echo(farEnd), 0.07), (echo(loud), 0.28), (us, 0.03)])
        try Self.writeTrack(
            to: system, seconds: 24,
            sources: [(farEnd.map { ($0.0 - 1, $0.1 - 1) }, 0.1), (loud.map { ($0.0 - 1, $0.1 - 1) }, 0.4)])

        // Engine timestamps run a little past the words, as Gemini's do.
        let segments = (farEnd.map { ($0, "A") } + us.map { ($0, "B") })
            .sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0 - 0.05, $0.0.1 + 0.25, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 1)
                == segments.map { $0.speaker == "A" ? "them" : "me" })
    }

    /// A far end speaking by the syllable, 100 ms in every 400, its echo
    /// 200 ms late as in a browser; and by the word, 400 ms in every 600, its
    /// echo within the bucket as on FaceTime. Read at one fixed delay out of
    /// step with the browser's echo, a quarter of the time the far end's
    /// track is on a syllable while the mic holds only the echo of the quiet
    /// between two. Read anywhere in the half second but its first 200 ms,
    /// once a word the track is loud throughout while the mic holds only the
    /// echo of the pause after it. Against that moment the echo looks twelve
    /// times weaker than it runs, and passes for us at any margin the gate
    /// could be given. No fixed delay within the half second is in step with
    /// both echoes.
    @Test(
        "A far end's syllables and words stay the far end, their echo late or at once",
        arguments: [(0.2, 0.1, 0.4), (0, 0.4, 0.6)])
    func syllablesAndWordsStayTheFarEnd(delay: Double, burst: Double, period: Double) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-syllables-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let farEnd = (0..<6).map { (2 + 4 * Double($0), 4 + 4 * Double($0)) }
        let syllables = farEnd.flatMap { turn in
            stride(from: turn.0, through: turn.1 - burst, by: period).map { ($0, $0 + burst) }
        }
        let us = farEnd.map { ($0.1 + 0.6, $0.1 + 1.3) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        let echo = { (bursts: [(Double, Double)]) in bursts.map { ($0.0 + delay, $0.1 + delay + 0.1) } }
        try Self.writeTrack(
            to: mic, seconds: 25,
            sources: [(echo(farEnd), 0.0175), (echo(syllables), 0.1925), (us, 0.03)])
        try Self.writeTrack(to: system, seconds: 25, sources: [(farEnd, 0.025), (syllables, 0.275)])

        let segments = (farEnd.map { ($0, "A") } + us.map { ($0, "B") })
            .sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0 - 0.05, $0.0.1 + 0.25, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
                == segments.map { $0.speaker == "A" ? "them" : "me" })
    }

    /// On headphones nothing on the far end's track comes back, neither its
    /// words nor the hum its open mic makes above the speech floor between
    /// them. The quietest tenth of mic over system stays near zero there,
    /// where a median would have us, talking over the hum more than half the
    /// call, taken for the echo of that hum.
    @Test("A far end humming between its words does not make our voice its echo")
    func farEndHumIsNotTakenForOurEcho() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-hum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let farEnd = [(1.0, 3.0), (8.0, 10.0), (15.0, 17.0)]
        let us = [(3.5, 7.5), (10.5, 14.5), (17.5, 20.0)]
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(to: mic, seconds: 20, bursts: us, gain: 0.03)
        try Self.writeTrack(
            to: system, seconds: 20, sources: [([(0, 20)], 0.014), (farEnd, 0.1)])

        let segments = (farEnd.map { ($0, "A") } + us.map { ($0, "B") })
            .sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0 + 0.05, $0.0.1 - 0.05, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
                == segments.map { $0.speaker == "A" ? "them" : "me" })
    }

    /// The same on headphones from a far end that mostly listens: its open
    /// mic clicks above the speech floor a third of the time and it says one
    /// word, under a hundredth of the call, so even its 99th percentile is the
    /// clicking. Taking the far end's speech from either made us, presenting
    /// over the clicks, their echo.
    @Test("A far end listening through a noisy open mic does not make our voice its echo")
    func noisyListenerIsNotTakenForOurEcho() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-listener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let us = [(0.5, 6.5), (7.5, 13.5), (14.5, 20.5), (23.0, 29.5)]
        let farEnd = [(21.0, 21.15)]
        let clicks = stride(from: 0.0, to: 30.0, by: 0.3).map { ($0, $0 + 0.1) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(to: mic, seconds: 30, bursts: us, gain: 0.03)
        try Self.writeTrack(to: system, seconds: 30, sources: [(clicks, 0.012), (farEnd, 0.1)])

        let segments = (farEnd.map { ($0, "A") } + us.map { ($0, "B") })
            .sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0 + 0.05, $0.0.1 - 0.05, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
                == segments.map { $0.speaker == "A" ? "them" : "me" })
    }

    /// A call recorded with nobody at the Mac (2026.10.07-1600): the mic holds
    /// the far end's echo, 400 ms late as a browser's can be, and the room
    /// under the speech floor. The few buckets of ring past the gate's reach
    /// are still read against the echo's level, the mic's own; against the
    /// room's, which is what remains once the echo is gone, they would read
    /// as somebody shouting and take every voice.
    ///
    /// A third voice only says "yes" between the turns. Its echo comes after
    /// its word is over and rings on, so a gate that looks back less than
    /// the half second that takes, or looks forward, hands that voice to us.
    @Test("A call recorded with nobody at the Mac stays on the far side")
    func nobodyAtTheMacStaysTheFarEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let turns = (0..<6).map { (2 + 4 * Double($0), 3.5 + 4 * Double($0)) }
        let yeses = (0..<5).map { (4.5 + 4 * Double($0), 4.8 + 4 * Double($0)) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(
            to: mic, seconds: 25,
            sources: [((turns + yeses).map { ($0.0 + 0.4, $0.1 + 0.7) }, 0.07), ([(0, 25)], 0.0035)])
        try Self.writeTrack(to: system, seconds: 25, bursts: turns + yeses, gain: 0.1)

        let voices = turns.enumerated().map { ($0.element, $0.offset % 2 == 0 ? "A" : "B") }
            + yeses.map { ($0, "C") }
        let segments = voices.sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0 - 0.05, $0.0.1 + 0.7, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
                == segments.map { "them \($0.speaker!)" })
    }

    /// What the gate costs has a bound: on the speakers, our answers starting
    /// over the end of the far end's turns, 12 dB louder than its echo, are
    /// still ours. A margin wide enough to swallow them would take every
    /// answer given before the far end has quite finished.
    @Test("Our answers over the end of the far end's turns, well above its echo, are ours")
    func loudAnswersOverTheEchoAreOurs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-answers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let farEnd = (0..<6).map { (2 + 4 * Double($0), 3.5 + 4 * Double($0)) }
        let us = farEnd.map { ($0.1 - 0.2, $0.1 + 0.3) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(
            to: mic, seconds: 25,
            sources: [(farEnd.map { ($0.0 + 0.15, $0.1 + 0.45) }, 0.07), (us, 0.3)])
        try Self.writeTrack(to: system, seconds: 25, bursts: farEnd, gain: 0.1)

        let segments = (farEnd.map { ($0, "A") } + us.map { ($0, "B") })
            .sorted { $0.0.0 < $1.0.0 }
            .map { Self.seg($0.0.0, $0.0.1, $0.1) }
        #expect(
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0)
                == segments.map { $0.speaker == "A" ? "them" : "me" })
    }

    /// The other way round it would be a guess. A system track with nothing
    /// on it is what a tap without its permission records (rca-002), and what
    /// an in-person meeting records too, so it cannot say whose voices the mic
    /// heard — and "me" for all of them could be wrong about everyone.
    @Test("A silent system track refuses to attribute rather than guessing")
    func silentSystemTrackRefuses() throws {
        let f = try Fixture()
        let silent = f.dir.appendingPathComponent("silent.caf")
        try Self.writeTrack(to: silent, seconds: 10, bursts: [], gain: 0)
        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(0.1, 1.9, "A"), Self.seg(6.1, 7.9, "B")],
                mic: f.mic, micOffset: 0, system: silent, systemOffset: 0) == nil)
    }

    /// A track that is digital zero nine tenths of the time has nothing at its
    /// 90th percentile to normalize against — a far end that said one thing
    /// in a meeting, a mic that died on a route change and came back — and
    /// that used to cost the whole meeting its sides.
    @Test("A far end heard only for a moment is still the far end")
    func aBriefFarEndIsStillAttributed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(to: mic, seconds: 10, bursts: [(0, 8)], gain: 0.08)
        try Self.writeTrack(to: system, seconds: 10, bursts: [(8.5, 9)], gain: 0.7)

        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(0.1, 7.9, "A"), Self.seg(8.5, 9.0, "B")],
                mic: mic, micOffset: 0, system: system, systemOffset: 0) == ["me", "them"])
    }

    @Test("No segments refuses to attribute")
    func noSegmentsRefuses() throws {
        let f = try Fixture()
        #expect(f.resolve([]) == nil)
    }

    @Test("The mix lays each track in at its own start offset")
    func mixHonoursOffsets() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [
                AudioMixer.Track(url: f.mic, offset: 0),
                AudioMixer.Track(url: f.system, offset: 0.5),
            ],
            to: mixed)
        let duration = try await AVURLAsset(url: mixed).load(.duration).seconds
        // 10s of track laid in at +0.5s.
        #expect(duration > 10.3 && duration < 11.0, "expected ~10.5s, got \(duration)")
    }

    @Test("The PCM tracks made by echo cancellation can be mixed at 16 kHz")
    func mixAcceptsEchoCancelledTracks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-aec-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Self.writeEchoCancelledTrack(to: mic, seconds: 1)
        try Self.writeEchoCancelledTrack(to: system, seconds: 1)

        let mixed = dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [AudioMixer.Track(url: mic, offset: 0), AudioMixer.Track(url: system, offset: 0)],
            to: mixed)

        let file = try AVAudioFile(forReading: mixed)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.length > 0)
    }

    /// A leftover mix from a failed run used to wedge every retry, since
    /// export refuses to overwrite.
    @Test("Mixing over an existing file replaces it")
    func mixOverwrites() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix([AudioMixer.Track(url: f.mic, offset: 0)], to: mixed)
        try await AudioMixer.mix([AudioMixer.Track(url: f.system, offset: 0)], to: mixed)
        #expect(FileManager.default.fileExists(atPath: mixed.path))
    }

    /// Duration alone would pass on a mix that quietly dropped one track, which
    /// is the failure that costs a meeting half its transcript. So look at the
    /// samples: each speaker's window has to be loud and the pauses quiet.
    @Test("Both tracks are audible in the mix, each in its own window")
    func mixCarriesBothTracks() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [
                AudioMixer.Track(url: f.mic, offset: 0),
                AudioMixer.Track(url: f.system, offset: 0.5),
            ],
            to: mixed)

        // mic speaks 0–2s, system 3.0–5.0s on the shared clock, both silent
        // in between; gains stay ~9x apart, so the check is against each
        // track's own level rather than a shared one.
        #expect(try Self.peak(of: mixed, from: 0.5, to: 1.5) > 0.04, "mic track missing")
        #expect(try Self.peak(of: mixed, from: 3.5, to: 4.5) > 0.3, "system track missing")
        #expect(try Self.peak(of: mixed, from: 2.0, to: 2.8) < 0.01, "silence between is not silent")
    }

    /// Two devices rarely agree on a sample rate — a 44.1k interface against a
    /// 48k tap is the ordinary case, and the old composition-based mix hid the
    /// resampling. Doing it by hand means a wrong ratio would stretch one
    /// track's timeline and put every far-side word in the wrong place.
    @Test("Tracks at different sample rates keep their timing")
    func mixResamplesWithoutDrift() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-rates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fast = dir.appendingPathComponent("mic.caf")
        let slow = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(to: fast, seconds: 10, bursts: [(0, 2)], gain: 0.5)
        try Self.writeTrack(to: slow, seconds: 10, bursts: [(7, 9)], gain: 0.5, rate: 44100)

        let mixed = dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [AudioMixer.Track(url: fast, offset: 0), AudioMixer.Track(url: slow, offset: 0)],
            to: mixed)

        // A 44.1/48 ratio applied the wrong way round would drag the 7–9s
        // burst to 6.4–8.3 or push it to 7.6–9.8; a whole second of margin
        // either side of the check catches both.
        #expect(try Self.peak(of: mixed, from: 0.5, to: 1.5) > 0.2, "48k track missing")
        #expect(try Self.peak(of: mixed, from: 7.5, to: 8.5) > 0.2, "44.1k track missing or drifted")
        #expect(try Self.peak(of: mixed, from: 4.0, to: 6.0) < 0.01, "silence between is not silent")
    }

    /// Loudest sample between two times, read straight off the file.
    private static func peak(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let first = AVAudioFramePosition(start * format.sampleRate)
        let frames = AVAudioFrameCount((end - start) * format.sampleRate)
        guard first < file.length, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frames)
        else { return 0 }
        file.framePosition = first
        try file.read(into: buffer, frameCount: frames)
        return AudioLevel.peak(of: buffer) ?? 0
    }
}
