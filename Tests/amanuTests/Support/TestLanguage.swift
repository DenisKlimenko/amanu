import Foundation
import Testing

@testable import amanu

/// A test, or every test in a suite, built in one interface language.
///
/// Through `InterfaceLanguage.$scoped`, which is the only way a test may
/// change the language: it is this test's task's language, so a window suite
/// in Russian cannot hand a Russian sentence to a test on another thread.
struct Speaking: TestTrait, SuiteTrait, TestScoping {
    let language: InterfaceLanguage

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await InterfaceLanguage.$scoped.withValue(language) { try await function() }
    }
}

extension Trait where Self == Speaking {
    static func speaking(_ language: InterfaceLanguage) -> Speaking { Speaking(language: language) }
}
