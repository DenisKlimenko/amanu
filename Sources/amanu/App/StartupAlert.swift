import Foundation

/// What the alert says when a check refuses to let amanu start.
///
/// The checks are `amanu doctor`'s, whose report stays English like every
/// command's output; the alert is a window, and it used to be the one window
/// in amanu that was English whatever the Mac spoke. A check that can refuse
/// a start carries its failure in the window's language as `explained`, and
/// the report's own words are only the fallback for one that does not.
enum StartupAlert {
    static var title: String {
        localised("Amanu could not start", "Amanu не удалось запуститься")
    }

    static func body(for checks: [Check]) -> String {
        checks.compactMap { check in
            guard case .fail(let why) = check.status else { return nil }
            if let explained = check.explained { return explained }
            return "\(check.name): \(why)" + (check.remediation.map { "\n" + $0 } ?? "")
        }.joined(separator: "\n\n")
    }
}
