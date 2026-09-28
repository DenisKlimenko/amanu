import Foundation
import Testing
@testable import amanu

@Suite("Analytics wire delivery")
struct AnalyticsDeliveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.875)

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        func keep(_ data: Data) { lock.withLock { stored.append(data) } }
        var requests: [Data] { lock.withLock { stored } }
    }

    private func event(_ index: Int) -> [String: Any] {
        ["queue_id": "event-\(index)", "type": "event", "payload": [
            "website": AnalyticsSink.Endpoint.websiteID, "hostname": "app.amanu.me",
            "url": "/", "name": "recording_started", "id": "test-installation",
            "timestamp": now.timeIntervalSince1970, "data": ["surface": "app"]]]
    }

    @Test("Both new and queued events send whole Unix seconds, including identify entries")
    func integerTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: ["pending": [event(0)]]).write(to: store)
        let capture = Capture()
        let sink = AnalyticsSink(store: store, transport: { body in capture.keep(body); return .retry },
                                 clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) },
                                 appVersion: { nil }, schedulesSends: false)
        sink.start(surface: .app)
        sink.record(.recordingFinished, [:])
        await sink.flush()
        let request = try #require(capture.requests.first)
        let entries = try #require(JSONSerialization.jsonObject(with: request) as? [[String: Any]])
        #expect(entries.count == 4)
        for entry in entries {
            let payload = try #require(entry["payload"] as? [String: Any])
            #expect(payload["timestamp"] as? Double == 1_800_000_000)
            #expect(entry["queue_id"] == nil)
        }
        #expect(sink.bufferedCount == 2)
    }

    @Test("A full persistent queue never exceeds Umami's 500-entry batch limit")
    func boundedBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: ["pending": (0..<500).map(event)]).write(to: store)
        let capture = Capture()
        let sink = AnalyticsSink(store: store, transport: { body in capture.keep(body); return .retry },
                                 clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) },
                                 appVersion: { nil }, schedulesSends: false)
        sink.start(surface: .app)
        await sink.flush()
        let request = try #require(capture.requests.first)
        let entries = try #require(JSONSerialization.jsonObject(with: request) as? [[String: Any]])
        #expect(entries.count <= 500)
        #expect(!entries.isEmpty)
        #expect(sink.bufferedCount == 500)
    }
    @Test("HTTP 200 acknowledges only entries not rejected inside the batch")
    func acknowledgementContract() {
        let success = Data(#"{"size":2,"processed":2,"errors":0,"details":[],"cache":"test-receipt"}"#.utf8)
        guard case .all = AnalyticsSink.deliveryResponse(status: 200, data: success, sentCount: 2) else {
            Issue.record("A complete receipt must acknowledge the batch")
            return
        }
        let partial = Data(#"{"size":2,"processed":1,"errors":1,"details":[{"index":1,"response":{"error":{"status":400,"message":"Bad request"}}}],"cache":"test-receipt"}"#.utf8)
        guard case .accepted(let indices) = AnalyticsSink.deliveryResponse(status: 200, data: partial, sentCount: 2) else {
            Issue.record("A partial receipt must preserve its accepted indices")
            return
        }
        #expect(indices == [0])
        for bad in [
            "{}", "[]", "not JSON",
            #"{"size":2,"processed":2,"errors":0,"details":[],"cache":null}"#,
            #"{"size":1,"processed":1,"errors":0,"details":[],"cache":"test-receipt"}"#,
            #"{"size":2,"processed":2,"errors":1,"details":[{"index":1}],"cache":"test-receipt"}"#,
            #"{"size":2,"processed":0,"errors":2,"details":[{"index":1},{"index":1}],"cache":"test-receipt"}"#,
            #"{"size":2,"processed":1,"errors":1,"details":[{"index":-1}],"cache":"test-receipt"}"#,
            #"{"size":2,"processed":1,"errors":1,"details":[{"index":2}],"cache":"test-receipt"}"#,
            #"{"size":2,"processed":0,"errors":2,"details":[],"cache":"test-receipt"}"#,
            #"{"size":2.5,"processed":2,"errors":0,"details":[],"cache":"test-receipt"}"#
        ] {
            guard case .retry = AnalyticsSink.deliveryResponse(status: 200, data: Data(bad.utf8), sentCount: 2) else {
                Issue.record("Malformed receipt retired events: \(bad)")
                continue
            }
        }
    }

    @Test("Partial receipts survive restart and retry neither accepted events nor accepted identities")
    func partialReceiptSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: ["pending": [event(0), event(1)]]).write(to: store)
        let partial = Data(#"{"size":4,"processed":2,"errors":2,"details":[{"index":0,"response":{"error":{"status":500}}},{"index":3,"response":{"error":{"status":400}}}],"cache":"test-receipt"}"#.utf8)
        var first: AnalyticsSink? = AnalyticsSink(store: store, transport: { _ in
            AnalyticsSink.deliveryResponse(status: 200, data: partial, sentCount: 4)
        }, clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) }, appVersion: { nil }, schedulesSends: false)
        first?.start(surface: .app)
        await first?.flush()
        #expect(first?.bufferedCount == 2)
        first = nil
        let capture = Capture()
        let next = AnalyticsSink(store: store, transport: { body in capture.keep(body); return .all },
                                 clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) },
                                 appVersion: { nil }, schedulesSends: false)
        next.start(surface: .app)
        await next.flush()
        #expect(next.bufferedCount == 0)
        let request = try #require(capture.requests.first)
        let entries = try #require(JSONSerialization.jsonObject(with: request) as? [[String: Any]])
        #expect(entries.compactMap { $0["type"] as? String } == ["identify", "event"])
        for entry in entries {
            #expect(entry["queue_id"] == nil)
            #expect(entry["identity_delivered"] == nil)
            #expect(entry["event_delivered"] == nil)
        }
    }

    @Test("A full queue drains as two accepted requests and persists no remaining events")
    func fullQueueDrains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("queue.json")
        try JSONSerialization.data(withJSONObject: ["pending": (0..<500).map(event)]).write(to: store)
        let capture = Capture()
        let sink = AnalyticsSink(store: store, transport: { body in capture.keep(body); return .all },
                                 clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) }, appVersion: { nil }, schedulesSends: false)
        sink.start(surface: .app)
        await sink.flush()
        #expect(sink.bufferedCount == 0)
        let sizes = try capture.requests.map { try #require(JSONSerialization.jsonObject(with: $0) as? [Any]).count }
        #expect(sizes == [500, 500])
    }

    @Test("Rejected HTTP-200 batches remain on disk for a later retry")
    func rejectedBatchPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("queue.json")
        let response = Data(#"{"size":2,"processed":0,"errors":2,"details":[{"index":0,"response":{"error":{"status":400}}},{"index":1,"response":{"error":{"status":400}}}],"cache":"test-receipt"}"#.utf8)
        let sink = AnalyticsSink(store: store, transport: { _ in
            AnalyticsSink.deliveryResponse(status: 200, data: response, sentCount: 2)
        }, clock: { now }, switchIsOn: { true }, identity: { ("test-installation", false) }, appVersion: { nil }, schedulesSends: false)
        sink.start(surface: .app)
        sink.record(.recordingStarted, [:])
        await sink.flush()
        #expect(sink.bufferedCount == 1)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        #expect((saved["pending"] as? [Any])?.count == 1)
    }

    @Test("The real Umami endpoint acknowledges a fractional legacy event after wire normalization",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_ANALYTICS_TEST_WEBSITE"] != nil))
    func liveUmamiContract() async throws {
        let website = try #require(ProcessInfo.processInfo.environment["AMANU_ANALYTICS_TEST_WEBSITE"])
        try #require(UUID(uuidString: website) != nil && website != AnalyticsSink.Endpoint.websiteID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("queue.json")
        let id = UUID().uuidString
        let fixture: [String: Any] = ["queue_id": "integration", "type": "event", "payload": [
            "website": website, "hostname": "analytics-test.invalid", "url": "/release-verification",
            "name": "recording_started", "id": id, "timestamp": Date().timeIntervalSince1970,
            "data": ["surface": "cli"]]]
        try JSONSerialization.data(withJSONObject: ["pending": [fixture]]).write(to: store)
        // Default transport: production URLSession, HTTP headers, encoder and
        // receipt parser. A dedicated website keeps user metrics untouched.
        let sink = AnalyticsSink(store: store, switchIsOn: { true }, identity: { (id, false) }, appVersion: { nil }, schedulesSends: false)
        sink.start(surface: .cli)
        await sink.flush()
        #expect(sink.bufferedCount == 0)
    }

}
