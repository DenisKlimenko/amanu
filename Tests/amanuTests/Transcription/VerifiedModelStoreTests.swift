import CryptoKit
import Darwin
import Foundation
import os
import Testing

@testable import amanu

/// One model, asked for by several parts of amanu at once, and by a download
/// that was interrupted.
struct VerifiedModelStoreTests {
    private let payload = Data((0..<4096).map { UInt8($0 % 251) })

    private var manifest: VerifiedModelStore.Manifest {
        .init(
            id: "fixture", fileName: "fixture.bin", revision: "fixture",
            downloadURL: URL(string: "https://models.example.test/fixture.bin")!,
            expectedBytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-model-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The setup window and the transcription queue asking for Whisper at the
    /// same moment used to download it twice into one `.partial`, each
    /// deleting what the other had written.
    @Test("Two callers at once share one download and both hear its progress")
    func concurrentCallersJoin() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = OSAllocatedUnfairLock(initialState: 0)
        let release = Gate()
        let payload = payload
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { _, partial, progress in
            started.withLock { $0 += 1 }
            await release.pass()
            try payload.write(to: partial)
            progress(.init(receivedBytes: Int64(payload.count), totalBytes: Int64(payload.count)))
        }
        let heard = OSAllocatedUnfairLock(initialState: [String]())

        async let first = store.download { _ in heard.withLock { $0.append("first") } }
        async let second = store.download { _ in heard.withLock { $0.append("second") } }
        while started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        release.open()
        let urls = try await [first, second]

        #expect(urls.allSatisfy { $0 == store.modelURL })
        #expect(started.withLock { $0 } == 1)
        #expect(Set(heard.withLock { $0 }) == ["first", "second"])
    }

    @Test("A caller that stops waiting leaves the download running for the other")
    func oneCancellationDoesNotStopTheOther() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let release = Gate()
        let started = Flag()
        let payload = payload
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { _, partial, _ in
            started.raise()
            await release.pass()
            try Task.checkCancellation()
            try payload.write(to: partial)
        }

        let impatient = Task { try await store.download() }
        let patient = Task { try await store.download() }
        while !started.isRaised { try await Task.sleep(for: .milliseconds(5)) }
        impatient.cancel()
        await #expect(throws: CancellationError.self) { try await impatient.value }
        release.open()

        #expect(try await patient.value == store.modelURL)
    }

    /// Another amanu — `amanu process` in a terminal — holding the model's
    /// lock is downloading it; this one waits and uses what it made.
    @Test("A download another process is making is waited for, not repeated")
    func anotherProcessHoldsTheLock() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = OSAllocatedUnfairLock(initialState: 0)
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { _, _, _ in
            downloads.withLock { $0 += 1 }
        }
        let other = open(store.lockURL.path, O_RDWR | O_CREAT, 0o644)
        #expect(flock(other, LOCK_EX) == 0)

        let waiting = Task { try await store.download() }
        try await Task.sleep(for: .milliseconds(400))
        try payload.write(to: store.modelURL)
        flock(other, LOCK_UN)
        close(other)

        #expect(try await waiting.value == store.modelURL)
        #expect(downloads.withLock { $0 } == 0)
    }

    @Test("A download cut off by the network keeps what it had for next time")
    func networkFailureKeepsThePartial() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = payload
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { _, partial, _ in
            try payload.prefix(1000).write(to: partial)
            throw URLError(.networkConnectionLost)
        }

        await #expect(throws: URLError.self) { try await store.download() }

        #expect(try Data(contentsOf: store.partialURL) == payload.prefix(1000))
    }

    @Test("An interrupted download asks the server only for the rest")
    func resumesWithARangeRequest() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = payload
        let server = StubHTTP { request, _ in
            if let range = request.header("Range"), range == "bytes=1000-" {
                return .status(206, body: payload.dropFirst(1000), headers: [
                    "Content-Range": "bytes 1000-\(payload.count - 1)/\(payload.count)",
                ])
            }
            return .status(200, body: payload)
        }
        let configuration = server.configuration
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { source, partial, progress in
            try await ModelDownloader.download(
                source: source, partial: partial, progress: progress, configuration: configuration)
        }
        try payload.prefix(1000).write(to: store.partialURL)
        let last = OSAllocatedUnfairLock<VerifiedModelStore.Progress?>(initialState: nil)

        let url = try await store.download { update in last.withLock { $0 = update } }

        #expect(try Data(contentsOf: url) == payload)
        #expect(server.requests.map { $0.header("Range") } == ["bytes=1000-"])
        #expect(last.withLock { $0 }?.fraction == 1)
        #expect(!FileManager.default.fileExists(atPath: store.partialURL.path))
    }

    @Test("A server that ignores the range sends the whole file, and the partial is replaced")
    func ignoredRangeStartsOver() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = payload
        let server = StubHTTP { _, _ in .status(200, body: payload) }
        let configuration = server.configuration
        let store = VerifiedModelStore(directory: dir, manifest: manifest) { source, partial, progress in
            try await ModelDownloader.download(
                source: source, partial: partial, progress: progress, configuration: configuration)
        }
        try Data(repeating: 7, count: 1000).write(to: store.partialURL)

        let url = try await store.download()

        #expect(try Data(contentsOf: url) == payload)
    }
}
