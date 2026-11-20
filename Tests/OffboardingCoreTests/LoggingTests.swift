import XCTest
@testable import OffboardingCore

final class LoggingTests: XCTestCase {
    func testAuthorizationHeaderIsRedacted() {
        let out = LogRedactor.redact("Authorization: Bearer abc.def.ghi-123")
        XCTAssertFalse(out.contains("abc.def"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func testJWTIsRedacted() {
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJl"
        XCTAssertFalse(LogRedactor.redact("token=\(jwt) end").contains(jwt))
    }

    func testOAuthFieldsAreRedacted() {
        let body = #"{"access_token":"SECRET1","refresh_token":"SECRET2","client_secret":"SECRET3"}"#
        let out = LogRedactor.redact(body)
        for secret in ["SECRET1", "SECRET2", "SECRET3"] { XCTAssertFalse(out.contains(secret)) }
        XCTAssertFalse(LogRedactor.redact("grant_type=authorization_code&code_verifier=VERIFIER").contains("VERIFIER"))
    }

    func testAuthorizationCodeInRedirectIsRedacted() {
        let out = LogRedactor.redact("msauth.com.app://auth?code=ABC123&state=xyz")
        XCTAssertFalse(out.contains("ABC123"))
        XCTAssertTrue(out.contains("state=xyz"))
    }

    func testGraphErrorCodeIsKept() {
        let msg = #"{"error":{"code":"Forbidden","message":"Insufficient privileges"}}"#
        XCTAssertEqual(LogRedactor.redact(msg), msg)
    }

    func testLoggerRedactsBeforeSink() {
        let captured = Captured()
        let logger = AppLogger(category: .auth) { _, _, message in captured.append(message) }
        logger.info("calling graph with Authorization: Bearer topsecret")
        XCTAssertEqual(captured.messages.count, 1)
        XCTAssertFalse(captured.messages[0].contains("topsecret"))
    }

    func testOperationSummaryShowsPartialSuccess() {
        let ok = OperationResult(asset: .managedDevice("1"), assetLabel: "Mac", action: .mdmWipe, state: .submitted)
        let bad = OperationResult(asset: .managedDevice("2"), assetLabel: "PC", action: .deleteIntuneRecord, state: .failed, httpStatus: 403)
        XCTAssertEqual(OffboardingResult(mode: .production, operations: [ok, bad]).summary, .completedWithWarnings)
        XCTAssertEqual(OffboardingResult(mode: .production, operations: [bad]).summary, .failed)
        XCTAssertEqual(OffboardingResult(mode: .production, operations: [ok]).summary, .completed)
    }

    func testNoActionIsNeverDestructiveAndDefaults() {
        XCTAssertEqual(OffboardingAction.default, .noAction)
        XCTAssertFalse(OffboardingAction.noAction.isDestructive)
        XCTAssertEqual(OffboardingAction.available(for: .mamRegistration), [.noAction, .mamSelectiveWipe])
        XCTAssertTrue(OffboardingAction.mdmWipe.requiresStrongConfirmation)
        XCTAssertFalse(OffboardingAction.deleteIntuneRecord.requiresStrongConfirmation)
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
