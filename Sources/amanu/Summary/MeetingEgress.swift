import Foundation

/// Where the words of a meeting may be sent, decided in one place for every
/// pass that hands them to a language model.
///
/// There are two such passes, naming the speakers and summarizing, and they
/// used to decide separately. Naming defaulted to `auto` whatever the summary
/// said, so a person who picked Ollama in setup precisely so that nothing left
/// this Mac still had every transcript read by the `claude` CLI first — and
/// one who turned summaries off entirely still had a cloud model read each
/// meeting to find names in it. Picking the Codex card sent naming to Claude.
/// The setup window's promise about where content goes was true of one pass
/// and false of the other.
///
/// The rule:
///
/// - The summary goes where `summary.backend` says, and nowhere when
///   summaries are off or the backend is `none`.
/// - Naming follows the summary, unless `speaker_names.backend` names a
///   backend of its own. With summaries off and no backend of its own, naming
///   asks no model at all: the person recording is still named from the
///   account, which needs nobody.
///
/// Anything new that wants to show a model a transcript asks here first.
enum MeetingEgress {
    enum Purpose: String, Sendable {
        case summary
        case speakerNames = "speaker_names"
    }

    /// Where one pass may go: a preference in `LLMBackend`'s vocabulary, and
    /// the Anthropic model to ask when one has been chosen by hand.
    struct Route: Equatable, Sendable {
        let preference: String
        /// nil when nobody chose one: the API then uses the summary's default
        /// and the `claude` CLI whatever Claude Code is set to.
        let anthropicModel: String?
    }

    /// The route for one pass under the current config, or nil when the
    /// meeting may not be shown to any model for it.
    static func route(for purpose: Purpose) -> Route? {
        route(for: purpose, summary: Config.summary(), names: Config.speakerNames())
    }

    static func route(
        for purpose: Purpose,
        summary: Config.SummarySettings,
        names: Config.SpeakerNamesSettings
    ) -> Route? {
        let summaryRoute = summary.enabled && summary.backend != "none"
            ? Route(preference: summary.backend, anthropicModel: summary.configuredModel)
            : nil
        switch purpose {
        case .summary:
            return summaryRoute
        case .speakerNames:
            guard names.enabled else { return nil }
            if let own = names.ownBackend {
                guard own != "none" else { return nil }
                return Route(
                    preference: own,
                    anthropicModel: names.model ?? summary.configuredModel)
            }
            guard let summaryRoute else { return nil }
            return Route(
                preference: summaryRoute.preference,
                anthropicModel: names.model ?? summaryRoute.anthropicModel)
        }
    }

    /// The backends one pass may try, in order; empty when it may try none.
    static func backends(for purpose: Purpose) -> [LLMBackend] {
        guard let route = route(for: purpose) else { return [] }
        return LLMBackend.available(
            preference: route.preference, anthropicModel: route.anthropicModel)
    }
}
