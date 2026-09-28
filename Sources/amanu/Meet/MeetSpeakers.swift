import Foundation

/// Names for the far end of a Google Meet call, taken from Meet itself.
///
/// Diarization can say that two voices differ and the naming pass can guess
/// who someone is from what they said, but Meet knows: it lights up the tile
/// of whoever is talking, and the tile carries the participant's name. The
/// browser extension in `Extensions/meet` writes down which tiles were lit and
/// when, through `amanu meet host`, into `directory`. This matches that
/// timeline against a finished transcript by the wall clock.
///
/// Only the far side is decided here. The mic track already says which words
/// are ours, and it says so from the audio itself; Meet's indicator is a
/// second opinion about the same thing, not a better one.
enum MeetSpeakers {
    /// One state of the call: who Meet showed as speaking from `t` on, until
    /// the next state. The extension repeats the current state every few
    /// seconds, so a gap longer than `stale` means it stopped reporting — a
    /// closed tab, a crashed browser — rather than that someone kept talking.
    struct Event: Decodable {
        struct Speaker: Decodable {
            let id: String
            let name: String?
            /// The extension's guess that this tile is ours. Our words are
            /// already known from the mic track, so our tile is only noise here.
            let `self`: Bool?
        }

        let t: Int
        let speaking: [Speaker]

        private enum CodingKeys: String, CodingKey { case t, speaking }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            t = try container.decode(Int.self, forKey: .t)
            // A "left the call" message carries no speakers at all, which is
            // exactly what it means.
            speaking = try container.decodeIfPresent([Speaker].self, forKey: .speaking) ?? []
        }
    }

    /// A stretch of one participant's tile being lit, in epoch milliseconds.
    struct Turn: Equatable {
        let id: String
        let name: String?
        let startMs: Int
        let endMs: Int
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/amanu/meet", isDirectory: true)

    /// Longer than the extension's heartbeat with room to spare.
    static let stale = 8_000

    /// How long a timeline is worth keeping. Past a month it can only ever be
    /// matched against a re-transcription of an old recording, and those are
    /// rare enough to cost nothing when they come out unnamed.
    static let retention: TimeInterval = 30 * 86_400

    // MARK: - the timeline

    /// Turns from one connection's events, in the order they were written.
    static func turns(from events: [Event]) -> [Turn] {
        var turns: [Turn] = []
        for (index, event) in events.enumerated() {
            let next = index + 1 < events.count ? events[index + 1].t : event.t + stale
            let end = min(next, event.t + stale)
            guard end > event.t else { continue }
            for speaker in event.speaking where speaker.`self` != true {
                turns.append(Turn(id: speaker.id, name: speaker.name, startMs: event.t, endMs: end))
            }
        }
        return turns
    }

    /// Every turn recorded between two moments, across however many
    /// connections the browser made — one per Meet tab, and a new one each
    /// time the extension's worker was restarted.
    static func turns(in dir: URL = directory, from startMs: Int, to endMs: Int) -> [Turn] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        var turns: [Turn] = []
        for file in files where file.pathExtension == "jsonl" {
            // Named for the moment the connection opened, and last written when
            // it closed: a file outside those two moments holds none of the
            // meeting, and a month of calls is not worth parsing to learn that.
            if let opened = Int(file.deletingPathExtension().lastPathComponent), opened > endMs {
                continue
            }
            if let written = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
               Int(written.timeIntervalSince1970 * 1000) < startMs {
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let decoder = JSONDecoder()
            let events = text.split(separator: "\n").compactMap {
                try? decoder.decode(Event.self, from: Data($0.utf8))
            }
            turns += Self.turns(from: events).filter { $0.endMs > startMs && $0.startMs < endMs }
        }
        return turns
    }

    /// Delete timelines past `retention`.
    static func prune(_ dir: URL = directory, now: Date = Date()) {
        let cutoff = Int(now.addingTimeInterval(-retention).timeIntervalSince1970 * 1000)
        for file in (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? [] {
            if let opened = Int(file.deletingPathExtension().lastPathComponent), opened < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - matching

    /// The far-end segments relabelled by the Meet participant who was
    /// speaking, and the name behind each new label. nil when the timeline has
    /// nothing to say about this transcript, which leaves it exactly as the
    /// engine and the track attribution left it.
    ///
    /// Two sources of evidence, in order:
    ///
    /// 1. **The segment's own time.** A participant whose tile was lit for at
    ///    least 30% of the utterance, and for at least twice as long as anyone
    ///    else's, spoke it. Most utterances are settled here.
    /// 2. **The segment's voice.** Short replies can finish before Meet's
    ///    indicator catches up, and two people talking over each other light
    ///    two tiles. When the engine's own label for a voice was matched to one
    ///    participant for at least three quarters of its settled time, its
    ///    unsettled utterances follow.
    ///
    /// Whatever is left is labelled plain `them`: somebody on the far end whom
    /// neither the timeline nor the voice could place. That keeps an honest
    /// "they said" rather than guessing a name.
    static func attribute(
        _ segments: [Transcript.Segment],
        turns: [Turn],
        originMs: Int
    ) -> (segments: [Transcript.Segment], names: [String: String])? {
        let theirs = segments.indices.filter { isFarEnd(segments[$0].speaker) }
        guard !theirs.isEmpty, !turns.isEmpty else { return nil }

        var direct: [Int: String] = [:]
        for index in theirs {
            direct[index] = dominant(segments[index], turns: turns, originMs: originMs)
        }

        var votes: [String: [String: Int]] = [:]
        for (index, participant) in direct {
            let segment = segments[index]
            votes[segment.speaker, default: [:]][participant, default: 0]
                += max(1, segment.end_ms - segment.start_ms)
        }
        let byVoice = votes.compactMapValues { tally -> String? in
            let total = tally.values.reduce(0, +)
            guard let top = tally.max(by: { $0.value < $1.value }),
                  top.value * 4 >= total * 3
            else { return nil }
            return top.key
        }

        let chosen = theirs.map { direct[$0] ?? byVoice[segments[$0].speaker] }
        guard chosen.contains(where: { $0 != nil }) else { return nil }

        // Letters in order of first appearance, so re-running over the same
        // meeting gives the same labels.
        var order: [String] = []
        for participant in chosen.compactMap({ $0 }) where !order.contains(participant) {
            order.append(participant)
        }
        let unplaced = chosen.contains { $0 == nil }
        let label: [String: String] = Dictionary(uniqueKeysWithValues: order.enumerated().map {
            ($0.element, order.count == 1 && !unplaced
                ? "them" : "them \(SpeakerAttribution.suffix($0.offset))")
        })

        var relabelled = segments
        for (index, participant) in zip(theirs, chosen) {
            let segment = segments[index]
            relabelled[index] = Transcript.Segment(
                speaker: participant.flatMap { label[$0] } ?? "them",
                start_ms: segment.start_ms,
                end_ms: segment.end_ms,
                text: segment.text)
        }

        // The most recent name wins: people rename themselves mid-call rarely,
        // and when they do the later name is the one they chose.
        var names: [String: String] = [:]
        for turn in turns.sorted(by: { $0.startMs < $1.startMs }) {
            if let key = label[turn.id], let name = turn.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                names[key] = name
            }
        }
        return (relabelled, names)
    }

    private static func isFarEnd(_ label: String) -> Bool {
        label == "them" || label.hasPrefix("them ")
    }

    private static func dominant(
        _ segment: Transcript.Segment,
        turns: [Turn],
        originMs: Int
    ) -> String? {
        let start = originMs + segment.start_ms
        let end = originMs + max(segment.end_ms, segment.start_ms + 1)
        var lit: [String: Int] = [:]
        for turn in turns where turn.endMs > start && turn.startMs < end {
            lit[turn.id, default: 0] += min(end, turn.endMs) - max(start, turn.startMs)
        }
        let ranked = lit.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value * 10 >= (end - start) * 3 else { return nil }
        if ranked.count > 1, ranked[1].value * 2 > top.value { return nil }
        return top.key
    }

    // MARK: - a session

    /// Apply the timeline to a session's freshly merged segments, record the
    /// names it yields in `speakers.json`, and return the segments to keep.
    ///
    /// Runs before `transcript.json` is written, so the transcript's first
    /// rendering already carries the names, and the naming pass that follows
    /// only asks a model about whoever Meet could not place.
    static func apply(
        to segments: [Transcript.Segment],
        session dir: URL,
        timeline: URL = directory,
        log: (String) -> Void
    ) -> [Transcript.Segment] {
        guard let origin = originMs(of: dir), let last = segments.map(\.end_ms).max() else {
            return segments
        }
        // Our own tile, when the extension could not tell it was ours: the
        // name on it is the one the naming pass would give the mic track.
        let owner = SpeakerNamer.ownerName()
        let turns = turns(in: timeline, from: origin, to: origin + last)
            .filter { $0.name == nil || $0.name != owner?.name }
        guard let result = attribute(segments, turns: turns, originMs: origin) else {
            return segments
        }

        var names = SpeakerNames.read(from: dir) ?? SpeakerNames()
        for (label, name) in result.names where names.speakers[label]?.source != .manual {
            names.speakers[label] = SpeakerNames.Entry(name: name, source: .meet)
        }
        // The naming pass only runs over a session with no speakers.json, so
        // once this writes one the pass is done — and the name it would still
        // have added, ours, is added here. Whoever Meet could not place stays
        // a plain `them` rather than going to a model.
        if let owner, names.speakers["me"]?.source != .manual,
           result.segments.contains(where: { $0.speaker == "me" }) {
            names.speakers["me"] = owner
        }
        do {
            try names.write(to: dir)
        } catch {
            log("couldn't write Meet speaker names: \(error)")
            return segments
        }
        log("Meet named " + result.names.sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }.joined(separator: ", "))
        return result.segments
    }

    /// The wall-clock moment a session's transcript counts from. Sessions
    /// recorded before `origin_ms` existed fall back to `started`, which is
    /// whole seconds and a little early — close enough for utterances that last
    /// several.
    static func originMs(of dir: URL) -> Int? {
        let meta = SessionState.read(dir) ?? [:]
        if let origin = meta["origin_ms"] as? Int { return origin }
        guard let started = (meta["started"] as? String)
            .flatMap({ ISO8601DateFormatter().date(from: $0) })
        else { return nil }
        return Int(started.timeIntervalSince1970 * 1000)
    }
}
