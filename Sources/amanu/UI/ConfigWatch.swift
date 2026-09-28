import AppKit
import Foundation

/// Redraw when the config file changes, whoever changed it.
///
/// Two windows now show the same form — setup is also the first tab of
/// settings — and both windows write the same file. A person who changed the
/// transcription provider in one and looked at the other saw the old answer
/// until the window was reopened: the file was right and the picture was
/// wrong, which is the worst way for a setting to fail, because it reads as
/// the change not having been saved.
///
/// So no window is told about any other. Each says what it renders, listens
/// for the file changing, and reads it again — the same thing it does when it
/// is reopened, which is the code path that was already trusted.
@MainActor
enum ConfigWatch {
    /// Call `redraw` after every successful write to the config file. Keep
    /// the returned token for as long as the redrawing is wanted; dropping it
    /// stops the observation.
    static func observe(_ redraw: @escaping @MainActor () -> Void) -> Token {
        Token(NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: nil
        ) { _ in
            // Delivered on whichever thread wrote — which today is always the
            // main one, since every writer is a control somebody clicked. The
            // check is here because "today" is not a guarantee, and AppKit
            // from a background thread is a crash rather than a glitch.
            if Thread.isMainThread {
                MainActor.assumeIsolated { redraw() }
            } else {
                DispatchQueue.main.async { redraw() }
            }
        })
    }

    /// Announces an edit made to the file by anyone other than this program —
    /// an editor, `amanu analytics off` from a terminal, a sync tool.
    ///
    /// `didChange` only ever came from `Config.update`, which was enough while
    /// every window was the only writer. It stopped being enough the day a
    /// broken file started to matter: amanu holds transcription while the file
    /// cannot be read, and the person fixes it in a text editor, so nothing
    /// inside the program would ever have heard that the fix was made.
    ///
    /// Polled rather than watched. A vnode source on the file is lost when an
    /// editor saves by renaming a new file over it, and one on the directory
    /// misses an editor that writes in place; comparing a stat every couple of
    /// seconds catches both and costs nothing worth measuring. A change this
    /// program made itself has already been announced, so the fingerprint is
    /// taken again after every `didChange` and the poll does not repeat it.
    ///
    /// The fingerprint sits behind a lock rather than on the main actor
    /// because `didChange` is delivered on whichever thread posted it.
    final class DiskWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var fingerprint: String?
        private var timer: Timer?
        private var observer: NSObjectProtocol?
        private let file: URL
        private let center: NotificationCenter

        /// `center` is only ever not the default one in a test, which needs
        /// announcements nobody else in a parallel suite is making.
        init(
            file: URL = Config.path, every interval: TimeInterval? = 2,
            center: NotificationCenter = .default
        ) {
            self.file = file
            self.center = center
            fingerprint = Self.fingerprint(of: file)
            observer = center.addObserver(
                forName: Config.didChange, object: nil, queue: nil
            ) { [weak self] _ in self?.remember() }
            if let interval {
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
                    [weak self] _ in self?.check()
                }
            }
        }

        /// Look once, and announce what changed. The timer calls this; a
        /// test calls it instead of waiting for the timer.
        func check() {
            let now = Self.fingerprint(of: file)
            lock.lock()
            let changed = now != fingerprint
            fingerprint = now
            lock.unlock()
            if changed { center.post(name: Config.didChange, object: nil) }
        }

        private func remember() {
            let now = Self.fingerprint(of: file)
            lock.lock()
            fingerprint = now
            lock.unlock()
        }

        private static func fingerprint(of file: URL) -> String? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = attributes[.size] as? Int ?? 0
            let inode = attributes[.systemFileNumber] as? Int ?? 0
            return "\(modified)/\(size)/\(inode)"
        }

        deinit {
            timer?.invalidate()
            if let observer { center.removeObserver(observer) }
        }
    }

    /// Keeps one observation alive, and ends it when it goes.
    final class Token {
        private let observer: NSObjectProtocol

        init(_ observer: NSObjectProtocol) { self.observer = observer }

        deinit { NotificationCenter.default.removeObserver(observer) }
    }
}
