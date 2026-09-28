import Foundation

/// The buffer and the sender.
///
/// Written by hand rather than hidden in an analytics SDK. Umami's batch API
/// is one JSON POST, so the complete reporting surface stays small enough to
/// read end to end and check against `docs/analytics.md`.
///
/// Three rules it does not break. Analytics never blocks a caller: `record`
/// hands work to a serial queue and returns. Analytics never fails loudly: a
/// send that does not work is written down and tried at the next launch, and
/// a store that cannot be written is dropped in silence. Analytics never
/// delays quitting by more than a moment — see `flush(waitingUpTo:)`.
final class AnalyticsSink: @unchecked Sendable {
    enum Delivery: Sendable {
        case all
        case accepted(Set<Int>)
        case retry
    }
    typealias Transport = @Sendable (Data) async -> Delivery

    private struct WireEntry: Sendable {
        let queueID: String
        let receiptKey: String
    }
    private struct Batch: Sendable {
        let body: Data
        let entries: [WireEntry]
    }

    /// Where events go. Umami's website id is public: it selects the dataset
    /// but grants no read access.
    enum Endpoint {
        static let url = URL(string: "https://stats.amanu.me/api/batch")!
        static let websiteID = "8ece1241-c45f-4976-9b20-d7004b2359b8"
        static var isConfigured: Bool { !websiteID.hasPrefix("UMAMI_WEBSITE_ID_REPLACE") }
    }

    static let shared = AnalyticsSink()

    /// Beside the identifier, so that forgetting everything amanu knows about
    /// this machine stays one `rm ~/.config/amanu/analytics*.json`.
    static var defaultStore: URL { Home.current.analyticsPendingFile }

    /// Past this the backlog is somebody who has been offline for a month,
    /// and the oldest of it has stopped being worth the disk.
    static let capacity = 500
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let flushInterval: TimeInterval = 30

    /// Who this machine is, and whether it has ever said so before. One
    /// answer rather than two calls, because asking for the identifier is
    /// what makes the file, and "is this the first run" is only true before
    /// that happens.
    typealias Identity = @Sendable () -> (id: String, isFirstRun: Bool)

    private let queue = DispatchQueue(label: "me.samat.amanu.analytics")
    private let store: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private let switchIsOn: @Sendable () -> Bool
    private let identity: Identity
    private let appVersion: @Sendable () -> String?
    private let markVersionSeen: @Sendable (String) -> Bool
    /// Whether there is anywhere to send to. False for a build whose project
    /// key is still the placeholder, so a development copy cannot quietly
    /// post at a host that does not exist yet — and true whenever a transport
    /// was handed in, because a caller that brought its own destination has
    /// said where things go.
    private let hasSomewhereToSend: Bool
    /// Whether sends happen by themselves — a second after starting and
    /// every half minute after — or only when somebody flushes. Always in the
    /// program; never in a test, where a send the clock started at a moment
    /// nobody chose is the difference between a test and a race.
    private let schedulesSends: Bool

    private var pending: [[String: Any]] = []
    private var enabled = false
    private var identifier = ""
    private var surface = Analytics.Surface.app
    private var started = false
    private var sending = false
    private var flushWaiters: [@Sendable () -> Void] = []
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    init(
        store: URL = AnalyticsSink.defaultStore,
        transport: Transport? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        switchIsOn: @escaping @Sendable () -> Bool = { AnalyticsIdentity.isEnabled() },
        identity: @escaping Identity = {
            // Read before asking, in this order and not the other one.
            let first = AnalyticsIdentity.isFirstRun()
            return (AnalyticsIdentity.identifier(), first)
        },
        appVersion: @escaping @Sendable () -> String? = { AnalyticsCatalogue.appVersion() },
        markVersionSeen: @escaping @Sendable (String) -> Bool = {
            AnalyticsIdentity.markVersionSeen($0)
        },
        schedulesSends: Bool = true
    ) {
        self.store = store
        self.transport = transport ?? AnalyticsSink.post
        self.clock = clock
        self.switchIsOn = switchIsOn
        self.identity = identity
        self.appVersion = appVersion
        self.markVersionSeen = markVersionSeen
        self.hasSomewhereToSend = transport != nil || Endpoint.isConfigured
        self.schedulesSends = schedulesSends
    }

    // MARK: - starting

    func start(surface: Analytics.Surface) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            self.surface = surface
            watchTheSwitch()
            if schedulesSends { startTimer() }
            enabled = switchIsOn()
            guard enabled else {
                try? FileManager.default.removeItem(at: store)
                return
            }

            let who = identity()
            identifier = who.id
            loadPending()
            if who.isFirstRun { append(.installed, [:]) }
            if let version = appVersion(), markVersionSeen(version) {
                append(.versionSeen, [:])
            }
        }
        if schedulesSends { flushSoon() }
    }

    /// A switch that only takes effect at the next launch is a switch people
    /// reasonably believe did nothing.
    private func watchTheSwitch() {
        observer = NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.reread() }
        }
    }

    private func reread() {
        guard started else { return }
        let nowEnabled = switchIsOn()
        guard nowEnabled != enabled else { return }
        enabled = nowEnabled
        if enabled {
            let who = identity()
            identifier = who.id
            if who.isFirstRun { append(.installed, [:]) }
            if let version = appVersion(), markVersionSeen(version) { append(.versionSeen, [:]) }
        } else {
            // Turning it off discards what has not gone yet. Anything else
            // would mean a switch that keeps sending for a week.
            pending = []
            try? FileManager.default.removeItem(at: store)
        }
    }

    // MARK: - recording

    func record(_ event: Analytics.Event, _ properties: [Analytics.Property: Analytics.Value]) {
        queue.async { [self] in
            guard started else { return }
            reread()
            guard enabled else { return }
            append(event, properties)
        }
    }

    private func append(
        _ event: Analytics.Event, _ properties: [Analytics.Property: Analytics.Value]
    ) {
        var data = AnalyticsCatalogue.personProperties()
        for (key, value) in properties { data[key.rawValue] = value.json }
        data = AnalyticsCatalogue.sanitized(data)
        data[Analytics.Property.surface.rawValue] = surface.rawValue
        pending.append([
            "queue_id": UUID().uuidString,
            "type": "event",
            "payload": [
                "hostname": "app.amanu.me",
                "url": "/",
                "title": "Amanu",
                "language": InterfaceLanguage.current.rawValue,
                "website": Endpoint.websiteID,
                "name": event.rawValue,
                "id": identifier,
                "timestamp": clock().timeIntervalSince1970,
                "data": data,
            ],
        ])
        trim()
        savePending()
    }

    private func trim() {
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
    }

    // MARK: - sending

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.send() }
        timer.resume()
        self.timer = timer
    }

    private func flushSoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.send() }
    }

    /// Send what is buffered and wait, but not for long.
    ///
    /// Quitting is an instruction, and analytics does not get a vote on it.
    /// Whatever has not gone when the wait runs out is already on disk and
    /// goes at the next launch — which is why the timeout can be this rude.
    ///
    /// This is the one call that blocks its thread, because quitting is
    /// synchronous. Anything that can wait properly — every test — awaits
    /// `flush()` instead: a semaphore held on a cooperative thread is a thread
    /// the transport it is waiting for may need, and that is how a timeout
    /// that was never going to matter became the suite's reason to run one
    /// test at a time.
    func flush(waitingUpTo seconds: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        flush { done.signal() }
        _ = done.wait(timeout: .now() + seconds)
    }

    /// Send what is buffered, and return once it has gone or failed to —
    /// however long that takes.
    func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            flush { done.resume() }
        }
    }

    /// Both flushes: start sending and call `finished` when the send this
    /// joins, or starts, is over. Enqueued before it returns, so everything
    /// recorded before it is included.
    func flush(then finished: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            reread()
            guard enabled, !pending.isEmpty else {
                finished()
                return
            }
            flushWaiters.append(finished)
            send()
        }
    }

    private func send() {
        guard started else { return }
        reread()
        guard enabled, !pending.isEmpty, hasSomewhereToSend else {
            finishFlushes()
            return
        }
        // An explicit flush may arrive after the timer started a request.
        // Leave its waiter attached to that request instead of pretending the
        // already-running send has completed.
        guard !sending else { return }
        pending = pending.filter { !isExpired($0) }
        savePending()
        guard let batch = encode(pending) else {
            finishFlushes()
            return
        }
        sending = true
        Task { [self] in
            let delivery = await transport(batch.body)
            queue.async { [self] in
                sending = false
                reread()
                let accepted: Set<Int>
                switch delivery {
                case .all: accepted = Set(batch.entries.indices)
                case .accepted(let indices): accepted = indices.intersection(batch.entries.indices)
                case .retry: accepted = []
                }
                if enabled, !accepted.isEmpty {
                    // Persist each wire acknowledgement independently. If an
                    // event succeeds but identify fails, retry only identify.
                    // Queue IDs also protect events appended during the send.
                    for index in accepted {
                        let entry = batch.entries[index]
                        if let position = pending.firstIndex(where: { $0["queue_id"] as? String == entry.queueID }) {
                            pending[position][entry.receiptKey] = true
                        }
                    }
                    pending.removeAll {
                        $0["identity_delivered"] as? Bool == true && $0["event_delivered"] as? Bool == true
                    }
                    savePending()
                }
                if accepted.count == batch.entries.count, !pending.isEmpty, !flushWaiters.isEmpty {
                    // Drain bounded batches during an explicit flush. Partial
                    // failures wait for the timer instead of retrying in a loop.
                    send()
                } else {
                    finishFlushes()
                }
            }
        }
    }

    private func finishFlushes() {
        let waiters = flushWaiters
        flushWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter() }
    }

    private func encode(_ events: [[String: Any]]) -> Batch? {
        var wire: [[String: Any]] = []
        var entries: [WireEntry] = []
        eventLoop: for event in events {
            guard let queueID = event["queue_id"] as? String,
                  var payload = event["payload"] as? [String: Any] else { continue }
            if let stamp = payload["timestamp"] as? Double {
                guard stamp.isFinite, stamp >= Double(Int64.min), stamp < Double(Int64.max) else { continue }
                // Normalize at the wire boundary, including persisted events
                // written by older versions with fractional seconds.
                payload["timestamp"] = Int64(stamp.rounded(.down))
            }
            if let data = payload["data"] as? [String: Any] {
                payload["data"] = AnalyticsCatalogue.sanitized(data)
            }
            for (type, key) in [("identify", "identity_delivered"), ("event", "event_delivered")] {
                guard event[key] as? Bool != true else { continue }
                if wire.count == 500 { break eventLoop }
                let part = type == "identify"
                    ? payload.filter { ["website", "hostname", "language", "id", "timestamp"].contains($0.key) }
                    : payload
                wire.append(["type": type, "payload": part])
                entries.append(WireEntry(queueID: queueID, receiptKey: key))
            }
        }
        guard !wire.isEmpty, let body = try? JSONSerialization.data(withJSONObject: wire) else { return nil }
        return Batch(body: body, entries: entries)
    }

    private static let post: Transport = { body in
        var request = URLRequest(url: Endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 10
        guard let count = (try? JSONSerialization.jsonObject(with: body) as? [Any])?.count,
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .retry }
        return deliveryResponse(status: http.statusCode, data: data, sentCount: count)
    }

    /// HTTP 200 confirms only the batch envelope. Umami reports individual
    /// rejection inside its JSON body; missing or inconsistent receipts must
    /// never cause events to disappear from the persistent queue.
    static func deliveryResponse(status: Int, data: Data, sentCount: Int) -> Delivery {
        struct Receipt: Decodable {
            struct Failure: Decodable { let index: Int }
            let size: Int
            let processed: Int
            let errors: Int
            let details: [Failure]
            let cache: String?
        }
        guard (200..<300).contains(status), sentCount > 0, sentCount <= 500,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.size == sentCount, receipt.errors >= 0, receipt.errors <= sentCount,
              receipt.processed == sentCount - receipt.errors,
              // Bot-filtered requests can be counted as processed without
              // storage. A real successful send supplies a session receipt.
              receipt.processed == 0 || receipt.cache?.isEmpty == false,
              receipt.details.count == receipt.errors else { return .retry }
        let rejected = Set(receipt.details.map(\.index))
        guard rejected.count == receipt.errors,
              rejected.allSatisfy({ (0..<sentCount).contains($0) }) else { return .retry }
        if rejected.isEmpty { return .all }
        return .accepted(Set(0..<sentCount).subtracting(rejected))
    }

    deinit {
        timer?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - the disk

    private func loadPending() {
        guard let data = try? Data(contentsOf: store),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["pending"] as? [[String: Any]]
        else { return }
        pending = stored.filter { !isExpired($0) }.map { event in
            var event = event
            if event["queue_id"] == nil { event["queue_id"] = UUID().uuidString }
            return event
        }
        trim()
    }

    private func savePending() {
        guard enabled else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["pending": pending]) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    private func isExpired(_ event: [String: Any]) -> Bool {
        guard let payload = event["payload"] as? [String: Any],
              let stamp = payload["timestamp"] as? Double
        else { return false }
        let date = Date(timeIntervalSince1970: stamp)
        return clock().timeIntervalSince(date) > Self.maximumAge
    }

    private static var userAgent: String {
        let version = AnalyticsCatalogue.appVersion() ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(os.majorVersion)_\(os.minorVersion)) "
            + "Amanu/\(version)"
    }

    // MARK: - for tests

    var bufferedCount: Int { queue.sync { pending.count } }
}
