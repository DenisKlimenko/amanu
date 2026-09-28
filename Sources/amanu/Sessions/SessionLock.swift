import Darwin
import Foundation

/// A short, exclusive hold on one session folder, for the read-modify-writes
/// of the small files in it — `meta.json` and `speakers.json`.
///
/// Those files are amended by several hands: the transcription queue, the
/// namer, the summarizer, a person renaming a speaker in the recordings
/// window, and `amanu process` in a terminal beside the app. Each read the
/// file, changed its own keys and wrote the whole thing back, so whichever
/// wrote second put back what the first had just removed or took away what
/// it had just added — a name typed by hand while a naming run was waiting on
/// its model was simply gone when the model answered.
///
/// The lock is `flock` on the folder itself rather than on a file inside it:
/// nothing is left behind for a person to find, and a folder deleted or moved
/// while somebody holds it takes the lock with it. `flock` belongs to the open
/// file description, so it excludes other parts of this process exactly as it
/// excludes another process — which is what the sweep and the window, both in
/// the app, need from it.
///
/// Held only for the length of a synchronous body, never across a model call:
/// the point is that the read and the write around a change are one step, and
/// a lock held for the minutes a model takes would stall the window for them.
enum SessionLock {
    /// The folders this task already holds, so that code which takes the lock
    /// can call other code that takes it without waiting on itself.
    @TaskLocal private static var held: Set<String> = []

    static func withLock<T>(_ dir: URL, _ body: () throws -> T) rethrows -> T {
        let key = dir.standardizedFileURL.path
        if held.contains(key) { return try body() }

        let descriptor = open(dir.path, O_RDONLY)
        var locked = false
        if descriptor >= 0 {
            while true {
                if flock(descriptor, LOCK_EX) == 0 { locked = true; break }
                if errno != EINTR { break }
            }
        }
        defer {
            if locked { flock(descriptor, LOCK_UN) }
            if descriptor >= 0 { close(descriptor) }
        }
        // A folder that cannot be opened or locked (a network volume without
        // flock) is still worked on, as it was before there was a lock: the
        // write that follows reports its own failure, and refusing here would
        // turn a missing lock into a missing summary.
        var inner = held
        inner.insert(key)
        return try $held.withValue(inner) { try body() }
    }
}
