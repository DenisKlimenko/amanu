import AVFoundation
import Foundation
import Testing
@testable import amanu

struct GigaAMEngineTests {
    @Test("Long recordings are kept inside GigaAM's 25-second input window")
    func longAudioIsChunkedAndOffset() async throws {
        let audio = try makeAudio(seconds: 45)
        let store = try fixtureStore()
        let runtime = RecordingGigaAMRuntime()
        let engine = GigaAMEngine(
            modelStore: store,
            runtime: runtime,
            chunkDuration: 20)

        try await engine.prepare()
        let segments = try await engine.transcribe(audio)

        #expect(engine.name == "gigaam")
        #expect(engine.model == "gigaam-v3-e2e-ctc-q8_0")
        #expect(engine.input.metadataName == "per-track")
        #expect(await runtime.sampleCounts == [320_000, 320_000, 80_000])
        #expect(segments.map(\.start) == [0, 20, 40])
        #expect(segments.map(\.end) == [20, 40, 45])
        #expect(segments.map(\.text) == ["фрагмент", "фрагмент", "фрагмент"])
    }

    @Test("GigaAM runtime failures remain retryable")
    func runtimeFailureIsRetryable() async throws {
        let engine = GigaAMEngine(
            modelStore: try fixtureStore(),
            runtime: FailingGigaAMRuntime())
        try await engine.prepare()

        await #expect(throws: GigaAMRuntimeFixtureError.self) {
            try await engine.transcribe(try makeAudio(seconds: 0.1))
        }
    }

    private func fixtureStore() throws -> GigaAMModelStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-gigaam-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data("model".utf8)
        let manifest = GigaAMModelStore.Manifest(
            id: "gigaam-v3-e2e-ctc-q8_0",
            fileName: "model.gguf",
            revision: "fixture",
            downloadURL: URL(string: "https://example.test/model.gguf")!,
            expectedBytes: Int64(payload.count),
            sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4")
        try payload.write(to: directory.appendingPathComponent(manifest.fileName))
        return GigaAMModelStore(directory: directory, manifest: manifest) { _, _, _ in
            Issue.record("an installed verified GigaAM model must not download")
        }
    }

    private func makeAudio(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-gigaam-audio-\(UUID().uuidString).caf")
        try TestAudio.write(to: url, seconds: seconds, sampleRate: 16_000) { _, _ in 0.2 }
        return url
    }
}

private struct GigaAMRuntimeFixtureError: Error {}

private actor RecordingGigaAMRuntime: GigaAMRuntime {
    private(set) var sampleCounts: [Int] = []
    func prepare(model: URL) async throws {}
    func transcribe(samples: [Float]) async throws -> String {
        sampleCounts.append(samples.count)
        return "фрагмент"
    }
    func release() async {}
}

private actor FailingGigaAMRuntime: GigaAMRuntime {
    func prepare(model: URL) async throws {}
    func transcribe(samples: [Float]) async throws -> String {
        throw GigaAMRuntimeFixtureError()
    }
    func release() async {}
}
