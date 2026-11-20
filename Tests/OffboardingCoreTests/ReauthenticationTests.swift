import XCTest
@testable import OffboardingCore

/// The fresh sign-in required before every production run.
final class ReauthenticationTests: XCTestCase {
    private func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
    }

    private var client: EntraOAuthClient { EntraOAuthClient(tenantId: "tenant-1", clientId: "client-1") }

    func testConfirmationSignInForcesCredentialsForTheExpectedAccount() throws {
        let url = try client.authorizationURL(
            redirectURI: "http://localhost:1", scopes: ["User.Read"], state: "s", nonce: "n", codeChallenge: "c",
            prompt: "login", loginHint: "admin+ops@contoso.com")
        XCTAssertEqual(items(url)["prompt"], "login")
        XCTAssertEqual(items(url)["login_hint"], "admin+ops@contoso.com") // percent-encoded on the wire, decoded here
        XCTAssertFalse(url.absoluteString.contains("admin+ops@")) // '+' and '@' must not be sent raw
    }

    func testNormalSignInIsUnchanged() throws {
        let url = try client.authorizationURL(
            redirectURI: "http://localhost:1", scopes: ["User.Read"], state: "s", nonce: "n", codeChallenge: "c")
        XCTAssertEqual(items(url)["prompt"], "select_account")
        XCTAssertNil(items(url)["login_hint"])
    }

    func testOnlyTheSameAccountInTheSameTenantCounts() {
        let me = AdminSession(accountId: "OID-1", username: "a@x.com", displayName: nil, tenantId: "T-1")
        XCTAssertTrue(me.isSameAccount(as: AdminSession(accountId: "oid-1", username: "renamed@x.com", displayName: "A", tenantId: "t-1")))
        XCTAssertFalse(me.isSameAccount(as: AdminSession(accountId: "OID-2", username: "a@x.com", displayName: nil, tenantId: "T-1")))
        XCTAssertFalse(me.isSameAccount(as: AdminSession(accountId: "OID-1", username: "a@x.com", displayName: nil, tenantId: "T-2")))
        let blank = AdminSession(accountId: "", username: "a@x.com", displayName: nil, tenantId: "T-1")
        XCTAssertFalse(blank.isSameAccount(as: blank)) // no object id: never "the same"
    }

    func testFailureMessageSaysNothingWasSent() {
        let issue = PlanValidationIssue.reauthenticationFailed("Sign-in was cancelled.")
        XCTAssertEqual(issue.localizedDescription, "Identity not confirmed, so nothing was sent. Sign-in was cancelled.")
    }
}
