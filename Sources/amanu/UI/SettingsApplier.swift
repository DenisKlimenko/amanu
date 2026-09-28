import Foundation

/// Every setting a running amanu can take up without starting again, taken
/// up the moment the config file says so.
///
/// Before this, each surface that wrote such a setting also did whatever
/// taking it up involved — and a surface that forgot did not. The live
/// transcript was the example: the status window's switch wrote the setting
/// and rewired the recording, and the same switch in the setup form wrote the
/// setting and did nothing else, so a meeting switched on from Settings went
/// on without it. Now every surface only writes, and this is the one reader.
///
/// What it does not take up is whatever `SettingsSchema` marks `needsRestart`
/// — the calendar watcher, the interface language, the window at launch —
/// which the settings window says applies at the next launch.
@MainActor
final class SettingsApplier {
    /// The runtime-changeable settings, as they stood at the last look.
    struct Snapshot: Equatable {
        var liveTranscription: Bool
        var menuBarIcon: Bool
        var dockIcon: Bool
        var recordingsRoot: URL

        static func read() -> Snapshot {
            Snapshot(
                liveTranscription: Config.liveTranscriptionEnabled(),
                menuBarIcon: Config.menuBarIcon(),
                dockIcon: Config.dockIcon(),
                recordingsRoot: Config.resolveRoot(cliOverride: nil).standardizedFileURL)
        }
    }

    /// One thing to take up.
    enum Change: Equatable {
        case liveTranscription(Bool)
        case icons
        case recordingsRoot(URL)
    }

    /// What changed between two looks, in the order it is best applied.
    static func changes(from old: Snapshot, to new: Snapshot) -> [Change] {
        var found: [Change] = []
        if old.liveTranscription != new.liveTranscription {
            found.append(.liveTranscription(new.liveTranscription))
        }
        if old.menuBarIcon != new.menuBarIcon || old.dockIcon != new.dockIcon {
            found.append(.icons)
        }
        if old.recordingsRoot != new.recordingsRoot {
            found.append(.recordingsRoot(new.recordingsRoot))
        }
        return found
    }

    private(set) var applied: Snapshot
    private var watch: ConfigWatch.Token?
    private let apply: @MainActor (Change) -> Void
    private let always: @MainActor () -> Void

    /// `apply` is handed each change once; `always` runs on every write, for
    /// the settings whose owner reads the file itself and only needs telling
    /// to look — automatic recording, which `AutoRecordController` settles.
    init(
        apply: @escaping @MainActor (Change) -> Void,
        always: @escaping @MainActor () -> Void = {}
    ) {
        applied = Snapshot.read()
        self.apply = apply
        self.always = always
        watch = ConfigWatch.observe { [weak self] in self?.configChanged() }
    }

    /// Read the file again and take up whatever moved. Public for the one
    /// caller that knows the file changed without a write announcing it.
    ///
    /// While the file cannot be read the getters answer with the settings
    /// last read from it, so a broken save changes nothing here. A process
    /// that has never read it has only defaults to go on, and those are not
    /// a change anybody made: the folder recordings are going into, the
    /// icons and the live transcript stay as they are until the file says
    /// otherwise.
    func configChanged() {
        guard !Config.settingsUnknown else {
            always()
            return
        }
        let now = Snapshot.read()
        let found = Self.changes(from: applied, to: now)
        applied = now
        for change in found { apply(change) }
        always()
    }
}
