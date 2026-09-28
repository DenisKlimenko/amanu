import Foundation

/// The revision-pinned GigaAM-v3 model consumed by transcribe.cpp.
/// Downloading, verifying and sharing it is `VerifiedModelStore`'s job.
struct GigaAMModelStore: Sendable {
    typealias Manifest = VerifiedModelStore.Manifest
    typealias Progress = VerifiedModelStore.Progress
    typealias Error = VerifiedModelStore.Error
    typealias ProgressHandler = VerifiedModelStore.ProgressHandler
    typealias Downloader = VerifiedModelStore.Downloader

    // Handy defaults to Q8_0. It keeps the CTC decoder fast while preserving
    // punctuation and Cyrillic casing, and is still only 259.5 MiB.
    static let defaultManifest = Manifest(
        id: "gigaam-v3-e2e-ctc-q8_0",
        fileName: "gigaam-v3-e2e-ctc-Q8_0.gguf",
        revision: "075dff81f843cf23d22b4ce943ffdc4dd8650cd7",
        downloadURL: URL(string:
            "https://huggingface.co/handy-computer/gigaam-v3-e2e-ctc-gguf/resolve/075dff81f843cf23d22b4ce943ffdc4dd8650cd7/gigaam-v3-e2e-ctc-Q8_0.gguf?download=true"
        )!,
        expectedBytes: 272_151_136,
        sha256: "9ccce4750dc813a493d96ca15ee251712bedec15ac9a02fa3d2bd732f08ae5eb")

    static let advertisedDownloadBytes: Int64 = defaultManifest.expectedBytes

    private let store: VerifiedModelStore

    init(
        directory: URL = Home.current.url
            .appendingPathComponent("Library/Application Support/amanu/models/gigaam", isDirectory: true),
        manifest: Manifest = GigaAMModelStore.defaultManifest,
        downloader: @escaping Downloader = { try await ModelDownloader.download(source: $0, partial: $1, progress: $2) }
    ) {
        store = VerifiedModelStore(directory: directory, manifest: manifest, downloader: downloader)
    }

    var directory: URL { store.directory }
    var manifest: Manifest { store.manifest }
    var modelURL: URL { store.modelURL }
    var partialURL: URL { store.partialURL }
    var bytesOnDisk: Int { store.bytesOnDisk }

    func download(progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        try await store.download(progress: progress)
    }

    func delete() throws { try store.delete() }
}
