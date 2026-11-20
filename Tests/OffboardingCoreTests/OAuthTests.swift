import XCTest
@testable import OffboardingCore

final class PKCETests: XCTestCase {
    /// RFC 7636, Appendix B test vector.
    func testChallengeMatchesRFC7636Vector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsValidAndUnique() {
        let first = PKCE.generate(), second = PKCE.generate()
        XCTAssertEqual(first.verifier.count, 43) // 32 random bytes, base64url without padding
        XCTAssertNotEqual(first.verifier, second.verifier)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(first.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testBase64URLRoundTrip() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x10])
        let text = Base64URL.encode(data)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Base64URL.decode(text), data)
    }
}

final class EntraOAuthTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    private func client(_ transport: MockTransport) -> EntraOAuthClient {
        EntraOAuthClient(tenantId: "tenant-1", clientId: "client-1", transport: transport, now: { [fixedNow] in fixedNow })
    }

    private func tokenJSON(expiresIn: Int = 3600, refresh: Bool = true) -> String {
        #"{"token_type":"Bearer","access_token":"AT","expires_in":\#(expiresIn),"id_token":"IDT"\#(refresh ? #","refresh_token":"RT""# : "")}"#
    }

    private func body(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: Authorization URL

    func testAuthorizationURLCarriesPKCEAndNoSecret() throws {
        let url = try client(MockTransport([])).authorizationURL(
            redirectURI: "http://localhost:54321", scopes: ["User.Read", "DeviceManagementManagedDevices.Read.All"],
            state: "st", nonce: "no", codeChallenge: "chal")
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(url.path, "/tenant-1/oauth2/v2.0/authorize")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "client-1")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "http://localhost:54321")
        XCTAssertEqual(items["code_challenge"], "chal")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "st")
        XCTAssertEqual(items["nonce"], "no")
        XCTAssertEqual(items["prompt"], "select_account")
        XCTAssertTrue(items["scope"]!.contains("offline_access"))
        XCTAssertTrue(items["scope"]!.contains("https://graph.microsoft.com/User.Read"))
        XCTAssertFalse(url.absoluteString.contains("secret"))
    }

    func testScopeStringExpandsBareNamesOnly() {
        let scopes = EntraOAuthClient.scopeString(["User.Read", "https://graph.microsoft.com/X.All", "openid"])
        XCTAssertEqual(scopes, "openid profile offline_access https://graph.microsoft.com/User.Read https://graph.microsoft.com/X.All")
    }

    // MARK: Token requests

    func testCodeExchangeIsASingleSecretFreePost() async throws {
        let t = MockTransport([.success(.init(status: 200, body: tokenJSON()))])
        let tokens = try await client(t).exchangeCode(
            "the-code", redirectURI: "http://localhost:5555", codeVerifier: "verifier", scopes: ["User.Read"])
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].httpMethod, "POST")
        XCTAssertEqual(t.requests[0].url?.path, "/tenant-1/oauth2/v2.0/token")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "Authorization"))
        let sent = body(t.requests[0])
        XCTAssertTrue(sent.contains("grant_type=authorization_code"))
        XCTAssertTrue(sent.contains("code_verifier=verifier"))
        XCTAssertTrue(sent.contains("redirect_uri=http%3A%2F%2Flocalhost%3A5555"))
        XCTAssertFalse(sent.contains("client_secret"))
        XCTAssertEqual(tokens.accessToken, "AT")
        XCTAssertEqual(tokens.refreshToken, "RT")
        XCTAssertEqual(tokens.expiresAt, fixedNow.addingTimeInterval(3600))
    }

    func testRefreshReportsExpiredSessionAsInteractionRequired() async {
        let t = MockTransport([.success(.init(status: 400, body: #"{"error":"invalid_grant","error_description":"AADSTS700082: expired\r\nTrace ID: x"}"#))])
        do {
            _ = try await client(t).refresh("RT", scopes: ["User.Read"])
            XCTFail("expected error")
        } catch { XCTAssertEqual(error as? AuthError, .interactionRequired) }
        XCTAssertEqual(t.requests.count, 1) // never retried
    }

    func testCodeExchangeErrorKeepsFirstLineOfDescription() async {
        let t = MockTransport([.success(.init(status: 400, body: #"{"error":"invalid_grant","error_description":"AADSTS65001: consent needed\r\nTrace ID: abc\r\nCorrelation ID: def"}"#))])
        do {
            _ = try await client(t).exchangeCode("c", redirectURI: "r", codeVerifier: "v", scopes: [])
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AuthError, .oauthFailure("invalid_grant: AADSTS65001: consent needed"))
        }
    }

    func testNetworkFailureIsAReadableAuthErrorNotRetried() async {
        let t = MockTransport([.failure(URLError(.notConnectedToInternet)), .success(.init(status: 200, body: tokenJSON()))])
        do {
            _ = try await client(t).refresh("RT", scopes: [])
            XCTFail("expected error")
        } catch {
            guard case .oauthFailure(let text)? = error as? AuthError else { return XCTFail("got \(error)") }
            XCTAssertTrue(text.contains("Could not reach Microsoft Entra"))
        }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testTokensNeverAppearInDescription() {
        let tokens = OAuthTokens(accessToken: "SECRET-AT", refreshToken: "SECRET-RT", idToken: "SECRET-ID", expiresAt: Date())
        XCTAssertFalse("\(tokens)".contains("SECRET"))
        XCTAssertFalse(String(reflecting: tokens).contains("SECRET"))
    }

    // MARK: ID token

    private func jwt(_ claims: [String: Any]) -> String {
        let header = Base64URL.encode(Data(#"{"alg":"none"}"#.utf8))
        let payload = Base64URL.encode((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
        return "\(header).\(payload).sig"
    }

    private let goodClaims: [String: Any] = [
        "aud": "client-1", "tid": "TENANT-1", "nonce": "n1", "oid": "obj-1",
        "preferred_username": "admin@contoso.com", "name": "Ada Admin",
    ]

    func testValidIDTokenYieldsAdminIdentity() throws {
        let claims = try IDToken.validate(jwt(goodClaims), clientId: "client-1", tenantId: "tenant-1", nonce: "n1")
        XCTAssertEqual(claims.username, "admin@contoso.com")
        XCTAssertEqual(claims.objectId, "obj-1")
        XCTAssertEqual(claims.name, "Ada Admin")
    }

    func testIDTokenFromAnotherTenantAppOrRequestIsRejected() {
        var wrongTenant = goodClaims; wrongTenant["tid"] = "other"
        XCTAssertThrowsError(try IDToken.validate(jwt(wrongTenant), clientId: "client-1", tenantId: "tenant-1", nonce: "n1")) {
            XCTAssertEqual($0 as? AuthError, .wrongTenant(expected: "tenant-1", actual: "other"))
        }
        var wrongAudience = goodClaims; wrongAudience["aud"] = "someone-else"
        XCTAssertThrowsError(try IDToken.validate(jwt(wrongAudience), clientId: "client-1", tenantId: "tenant-1", nonce: "n1"))
        var wrongNonce = goodClaims; wrongNonce["nonce"] = "replayed"
        XCTAssertThrowsError(try IDToken.validate(jwt(wrongNonce), clientId: "client-1", tenantId: "tenant-1", nonce: "n1"))
        XCTAssertThrowsError(try IDToken.validate("not-a-jwt", clientId: "client-1", tenantId: "tenant-1", nonce: "n1"))
    }
}
