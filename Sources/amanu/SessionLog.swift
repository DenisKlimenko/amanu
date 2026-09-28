import Foundation

/// Append one line to a session's `transcribe.log`.
///
/// A free function rather than a method so both the transcription actor and
/// the summarizer can write progress as it happens: handing the summarizer a
/// closure that captured the actor would mean sending non-Sendable state across
/// an isolation boundary, and buffering the lines until the end would hide
/// exactly the part that takes minutes.
///
/// It never fails its caller. The log is a diary, and a diary that cannot be
/// written must not take the recording down with it: the legacy
/// `FileHandle.write(_: Data)` raised an Objective-C exception on a full disk
/// or an I/O error, which Swift cannot catch, so one log line written during a
/// meeting on a nearly full disk could end the process mid-recording. The
/// throwing API is used instead, and a line that cannot be written is said on
/// stderr and dropped.
func appendSessionLog(_ message: String, to dir: URL) {
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
    let url = dir.appendingPathComponent("transcribe.log")
    // O_APPEND rather than a seek: two processes can log to one session, and
    // an append is placed at the end by the kernel, not by whoever looked last.
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else {
        SessionLog.complain("couldn't open \(url.path): \(String(cString: strerror(errno)))")
        return
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
        try SessionLog.append(line, to: handle)
    } catch {
        SessionLog.complain("couldn't write \(url.path): \(error)")
    }
}

enum SessionLog {
    /// The write itself, apart from finding the file, so that a handle which
    /// refuses the write can be handed in directly — a full disk is not
    /// something a test can arrange, and a handle opened read-only fails the
    /// same call in the same way.
    static func append(_ line: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: line)
    }

    /// stderr through the C library rather than `FileHandle.standardError`,
    /// whose `write` is the same legacy call and raises on a closed pipe.
    static func complain(_ message: String) {
        fputs("amanu: \(message)\n", stderr)
    }
}
