import Foundation
import Testing

@testable import amanu

/// Whether the tests that exercise the real echo canceller run.
///
/// LocalVQE is built by `make localvqe` into `.build/localvqe`, which a fresh
/// checkout does not have, so on a developer's Mac those tests are skipped —
/// and said to be skipped — rather than failing for a reason that has nothing
/// to do with what was changed. CI builds the assets first and sets
/// `AMANU_REQUIRE_LOCALVQE=1`, and there the tests always run: assets that
/// failed to appear are then a failure, not a quiet skip.
enum LocalVQEGate {
    static var required: Bool {
        ProcessInfo.processInfo.environment["AMANU_REQUIRE_LOCALVQE"] == "1"
    }

    static var runs: Bool { required || LocalVQEAssets.areAvailable }
}

@Suite("LocalVQE is there when it is required")
struct LocalVQEGateTests {
    @Test("CI has the echo canceller the release ships", .enabled(if: LocalVQEGate.required))
    func requiredAssetsArePresent() throws {
        _ = try LocalVQEAssets.resolve()
    }
}
