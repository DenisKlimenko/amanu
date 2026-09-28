import Foundation

extension Config {
    /// Something wrong with the config file that the person needs to hear
    /// about, because amanu is doing something other than what the file says.
    ///
    /// Every surface that could be the one somebody looks at says it: the
    /// menu, the status window, the setup form, the settings window and
    /// `amanu doctor`. A config problem shown in only one of them is shown to
    /// nobody who happened to look at the others.
    enum Problem: Equatable {
        /// The file is there and is not JSON — see `Config.File`.
        case unreadable(reason: String)

        /// One line, for the menu and the status window, where there is room
        /// for the fact and not for its explanation.
        var headline: String {
            switch self {
            case .unreadable:
                return localised(
                    "config.json can't be read — transcription and summaries are waiting",
                    "config.json не читается — расшифровка и саммари ждут")
            }
        }

        /// The whole account, for the windows with room for it and for the
        /// doctor: what is wrong, and what amanu is doing instead.
        var explanation: String {
            switch self {
            case .unreadable(let reason):
                return localised(
                    "config.json can't be read (\(reason)). Until it is fixed, amanu uses its "
                        + "defaults and keeps recording, but holds transcription and summaries, "
                        + "sends no usage statistics, and saves no changed settings.",
                    "config.json не читается (\(reason)). Пока файл не исправлен, amanu работает "
                        + "с настройками по умолчанию и продолжает записывать, но расшифровка и "
                        + "саммари ждут, статистика не отправляется, а изменённые настройки "
                        + "не сохраняются.")
            }
        }
    }

    /// Everything wrong with the file as it is now, most serious first.
    static func problems() -> [Problem] {
        switch file() {
        case .absent, .parsed: return []
        case .unreadable(let reason): return [.unreadable(reason: reason)]
        }
    }
}
