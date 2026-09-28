import CryptoKit
import Darwin
import Foundation

/// One revision-pinned model file, downloaded once per Mac however many parts
/// of amanu want it at the same moment.
///
/// The URL is pinned to an immutable revision and the file's size and digest
/// are checked after every download. A response reaching 100% therefore is
/// not enough to make it a model: only a verified `.partial` is renamed to the
/// canonical path.
///
/// Four things can ask for the same model at once — the setup window, the
/// settings window, the transcription queue, and `amanu process` in another
/// process — and they used to share one `.partial` path with nothing between
/// them: each deleted the other's half-downloaded file and started again from
/// zero, and whichever finished first verified a file somebody else was still
/// writing. So:
///
/// - within a process, a second `download` joins the one in flight, sees its
///   progress, and gets its answer;
/// - across processes, the download runs under an exclusive `flock` on a lock
///   file beside the model, and whoever waited for it finds the model there;
/// - a download that stopped for any reason other than a bad file leaves its
///   `.partial` behind, and the next one asks the server for the rest of it
///   with a `Range` request instead of starting over.
///
/// Each caller keeps its own cancellation: a caller that stops waiting stops
/// waiting, and the download itself stops only when nobody is waiting for it
/// any more.
struct VerifiedModelStore: Sendable {
    struct Manifest: Equatable, Sendable {
        let id: String
        let fileName: String
        let revision: String
        let downloadURL: URL
        let expectedBytes: Int64
        let sha256: String
    }

    struct Progress: Equatable, Sendable {
        let receivedBytes: Int64
        let totalBytes: Int64?

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
        }
    }

    enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case badHTTPStatus(Int)
        case invalidSize(expected: Int64, actual: Int64)
        case invalidSHA256
        case missingDownloadedFile

        var description: String {
            switch self {
            case .badHTTPStatus(let status): return "model download returned HTTP \(status)"
            case .invalidSize(let expected, let actual):
                return "model file is \(actual) bytes; expected \(expected)"
            case .invalidSHA256: return "model file's SHA-256 does not match its manifest"
            case .missingDownloadedFile: return "model download produced no file"
            }
        }

        /// The file itself is wrong, so what is on disk cannot be resumed.
        var condemnsPartial: Bool {
            switch self {
            case .invalidSize, .invalidSHA256: return true
            case .badHTTPStatus(let status): return status == 416
            case .missingDownloadedFile: return false
            }
        }
    }

    typealias ProgressHandler = @Sendable (Progress) -> Void
    /// Fetch `source` into `partial`. A partial file that is already there is
    /// the beginning of the download: a downloader that can resume appends to
    /// it, and one that cannot overwrites it.
    typealias Downloader = @Sendable (
        _ source: URL,
        _ partial: URL,
        _ progress: @escaping ProgressHandler
    ) async throws -> Void

    let directory: URL
    let manifest: Manifest
    private let downloader: Downloader

    init(directory: URL, manifest: Manifest, downloader: @escaping Downloader) {
        self.directory = directory
        self.manifest = manifest
        self.downloader = downloader
    }

    var modelURL: URL { directory.appendingPathComponent(manifest.fileName) }
    var partialURL: URL { URL(fileURLWithPath: modelURL.path + ".partial") }
    var lockURL: URL { URL(fileURLWithPath: modelURL.path + ".lock") }

    var bytesOnDisk: Int {
        (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The verified model, downloading it first if it is not here yet.
    func download(progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        if try installedModel() != nil { return modelURL }
        let shared = SharedDownloads.shared.download(for: modelURL.path) { [self] fanOut in
            try await downloadUnderLock(progress: fanOut)
        }
        return try await shared.wait(progress: progress)
    }

    func delete() throws {
        for url in [modelURL, partialURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The installed model if it is there and verifies; a file that does not
    /// is removed. Cancelling the check never removes anything.
    private func installedModel() throws -> URL? {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        do {
            try Self.verify(modelURL, against: manifest)
            return modelURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: modelURL)
            return nil
        }
    }

    private func downloadUnderLock(progress: @escaping ProgressHandler) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(lockURL)
        defer { lock.release() }
        // Whoever held the lock before us may have finished the job.
        if try installedModel() != nil { return modelURL }

        let partialBytes = Self.size(of: partialURL)
        if partialBytes >= manifest.expectedBytes {
            // Everything is there already; only the verdict is missing.
            if (try? install()) != nil { return modelURL }
            try? FileManager.default.removeItem(at: partialURL)
        }
        do {
            try await downloader(manifest.downloadURL, partialURL, progress)
            try Task.checkCancellation()
            try install()
            return modelURL
        } catch let error as Error where error.condemnsPartial {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    /// Verify the partial file and move it into place.
    private func install() throws {
        guard FileManager.default.fileExists(atPath: partialURL.path) else {
            throw Error.missingDownloadedFile
        }
        do {
            try Self.verify(partialURL, against: manifest)
        } catch let error as Error {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: partialURL, to: modelURL)
    }

    private static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func verify(_ url: URL, against manifest: Manifest) throws {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == manifest.expectedBytes else {
            throw Error.invalidSize(expected: manifest.expectedBytes, actual: size)
        }
        guard try sha256(of: url) == manifest.sha256.lowercased() else {
            throw Error.invalidSHA256
        }
    }

    /// Incremental hashing keeps model verification at a fixed memory cost.
    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - one download, several callers

/// The downloads in flight in this process, by model path.
final class SharedDownloads: @unchecked Sendable {
    static let shared = SharedDownloads()

    private let lock = NSLock()
    private var running: [String: SharedDownload] = [:]

    func download(
        for key: String,
        start: @escaping @Sendable (@escaping VerifiedModelStore.ProgressHandler) async throws -> URL
    ) -> SharedDownload {
        lock.lock()
        defer { lock.unlock() }
        if let existing = running[key], !existing.isAbandoned { return existing }
        let download = SharedDownload(work: start) { [weak self] finished in
            self?.forget(key, finished)
        }
        running[key] = download
        return download
    }

    private func forget(_ key: String, _ download: SharedDownload) {
        lock.lock()
        defer { lock.unlock() }
        if running[key] === download { running[key] = nil }
    }
}

/// One download and everybody waiting for it.
final class SharedDownload: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<URL, Error>
        let progress: VerifiedModelStore.ProgressHandler
    }

    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]
    private var result: Result<URL, Error>?
    private var abandoned = false
    private var task: Task<Void, Never>?

    init(
        work: @escaping @Sendable (@escaping VerifiedModelStore.ProgressHandler) async throws -> URL,
        finished: @escaping @Sendable (SharedDownload) -> Void
    ) {
        task = Task.detached(priority: .utility) { [self] in
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try await work { [self] update in report(update) })
            } catch {
                outcome = .failure(error)
            }
            complete(outcome)
            finished(self)
        }
    }

    var isAbandoned: Bool { lock.withLock { abandoned } }

    func wait(progress: @escaping VerifiedModelStore.ProgressHandler) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(continuation: continuation, progress: progress)
                    lock.unlock()
                }
            }
        } onCancel: {
            leave(id)
        }
    }

    /// One caller stops waiting. The download stops with the last of them.
    private func leave(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        let nobodyLeft = waiters.isEmpty && result == nil
        if nobodyLeft { abandoned = true }
        let task = nobodyLeft ? self.task : nil
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
        task?.cancel()
    }

    private func report(_ update: VerifiedModelStore.Progress) {
        let handlers = lock.withLock { waiters.values.map(\.progress) }
        for handler in handlers { handler(update) }
    }

    private func complete(_ outcome: Result<URL, Error>) {
        lock.lock()
        result = outcome
        let waiting = waiters.values
        waiters = [:]
        lock.unlock()
        for waiter in waiting { waiter.continuation.resume(with: outcome) }
    }
}

// MARK: - one download, several processes

/// An exclusive `flock` on a file, waited for without blocking a thread and
/// given up on when the task is cancelled. The kernel drops it if the process
/// dies, so a crash mid-download cannot leave the model locked.
struct FileLock: Sendable {
    private let descriptor: Int32

    static func acquire(_ url: URL, poll: Duration = .milliseconds(250)) async throws -> FileLock {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: url.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)),
            ])
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            do {
                try await Task.sleep(for: poll)
            } catch {
                close(descriptor)
                throw error
            }
        }
        return FileLock(descriptor: descriptor)
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MARK: - HTTP

/// The model download over HTTP, resuming a partial file where the server
/// allows it.
enum ModelDownloader {
    static func download(
        source: URL,
        partial: URL,
        progress: @escaping VerifiedModelStore.ProgressHandler,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws {
        let existing = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        let delegate = Delegate(partial: partial, offset: existing, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: source)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(continuation: continuation)
                let task = session.dataTask(with: request)
                delegate.attach(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partial: URL
        private let offset: Int64
        private let progress: VerifiedModelStore.ProgressHandler
        private let lock = NSLock()
        private var file: FileHandle?
        private var continuation: CheckedContinuation<Void, Swift.Error>?
        private var task: URLSessionTask?
        private var received: Int64 = 0
        private var expected: Int64?
        private var finished = false
        private var cancelled = false

        init(partial: URL, offset: Int64, progress: @escaping VerifiedModelStore.ProgressHandler) {
            self.partial = partial
            self.offset = offset
            self.progress = progress
        }

        func begin(continuation: CheckedContinuation<Void, Swift.Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func attach(_ task: URLSessionTask) {
            lock.withLock {
                self.task = task
                if finished || cancelled { task.cancel() }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                task?.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                completionHandler(.cancel)
                complete(.failure(VerifiedModelStore.Error.badHTTPStatus(status)))
                return
            }
            // 206 is the rest of the file after what we have; anything else
            // is the whole file, and what we had is thrown away.
            let resuming = status == 206 && offset > 0
            do {
                if !FileManager.default.fileExists(atPath: partial.path) || !resuming {
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: partial)
                if resuming { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
                received = resuming ? offset : 0
                let length = response.expectedContentLength
                expected = length > 0 ? received + length : nil
                lock.withLock { file = handle }
                completionHandler(.allow)
            } catch {
                completionHandler(.cancel)
                complete(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try lock.withLock { file }?.write(contentsOf: data)
                received += Int64(data.count)
                progress(.init(receivedBytes: received, totalBytes: expected))
            } catch {
                dataTask.cancel()
                complete(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Swift.Error?
        ) {
            if let error {
                let wasCancelled = lock.withLock { cancelled }
                complete(.failure(wasCancelled ? CancellationError() : error))
            } else {
                complete(.success(()))
            }
        }

        private func complete(_ result: Result<Void, Swift.Error>) {
            let continuation: CheckedContinuation<Void, Swift.Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                try? file?.close()
                file = nil
                let saved = self.continuation
                self.continuation = nil
                return saved
            }
            continuation?.resume(with: result)
        }
    }
}
