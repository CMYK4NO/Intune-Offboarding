import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tokens held in memory only. `description` is redacted so a stray `print` or log line can never
/// leak them.
public struct OAuthTokens: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
    }

    public var description: String { "OAuthTokens(<redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

/// Who signed in, taken from the ID token claims.
public struct AdminClaims: Equatable, Sendable {
    public let tenantId: String
    public let objectId: String
    public let username: String
    public let name: String?
}

public enum IDToken {
    /// Reads and checks the claims that bind the ID token to THIS sign-in request.
    ///
    /// The token is received directly from the token endpoint over TLS, so its signature is not
    /// verified again (OpenID Connect Core 3.1.3.7); audience, tenant and nonce are.
    public static func validate(_ jwt: String, clientId: String, tenantId: String, nonce: String) throws -> AdminClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = Base64URL.decode(String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw AuthError.oauthFailure("The sign-in response contained an unreadable identity token.")
        }
        guard let audience = claims["aud"] as? String, audience.caseInsensitiveCompare(clientId) == .orderedSame else {
            throw AuthError.oauthFailure("The identity token was issued for a different application.")
        }
        guard let tenant = claims["tid"] as? String else {
            throw AuthError.oauthFailure("The identity token has no tenant.")
        }
        guard tenant.caseInsensitiveCompare(tenantId) == .orderedSame else {
            throw AuthError.wrongTenant(expected: tenantId, actual: tenant)
        }
        guard (claims["nonce"] as? String) == nonce else {
            throw AuthError.oauthFailure("The identity token does not belong to this sign-in attempt.")
        }
        let objectId = (claims["oid"] as? String) ?? (claims["sub"] as? String) ?? ""
        let username = (claims["preferred_username"] as? String) ?? (claims["upn"] as? String) ?? "unknown"
        return AdminClaims(tenantId: tenant, objectId: objectId, username: username, name: claims["name"] as? String)
    }
}

/// OAuth 2.0 Authorization Code flow with PKCE against Microsoft Entra ID (v2.0 endpoints),
/// for a native PUBLIC client: there is no client secret anywhere in these requests.
///
/// Token requests are sent once and never retried: an authorization code is single-use, and a
/// refresh failure must reach the caller instead of being hidden.
public struct EntraOAuthClient: Sendable {
    public static let defaultHost = URL(string: "https://login.microsoftonline.com")!

    private let tenantId: String
    private let clientId: String
    private let transport: HTTPTransport
    private let host: URL
    private let now: @Sendable () -> Date

    public init(
        tenantId: String, clientId: String,
        transport: HTTPTransport = URLSessionTransport(),
        host: URL = EntraOAuthClient.defaultHost,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tenantId = tenantId
        self.clientId = clientId
        self.transport = transport
        self.host = host
        self.now = now
    }

    /// OpenID scopes (id token, refresh token) plus the Graph scopes. Bare names such as
    /// "User.Read" are expanded to their Microsoft Graph resource URI.
    public static func scopeString(_ scopes: [String]) -> String {
        let openID = ["openid", "profile", "offline_access"]
        let resource = scopes
            .map { $0.contains("/") ? $0 : "https://graph.microsoft.com/\($0)" }
            .filter { !openID.contains($0) }
        return (openID + resource).joined(separator: " ")
    }

    // MARK: - Authorization request (opened in the default browser)

    /// `prompt` is "select_account" for a normal sign-in and "login" to force the administrator to enter credentials
    /// again (used to confirm identity right before a production run). `loginHint` pre-fills the expected account.
    public func authorizationURL(
        redirectURI: String, scopes: [String], state: String, nonce: String, codeChallenge: String,
        prompt: String = "select_account", loginHint: String? = nil
    ) throws -> URL {
        var query: [(String, String)] = [
            ("client_id", clientId),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("response_mode", "query"),
            ("scope", Self.scopeString(scopes)),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("prompt", prompt),
        ]
        if let loginHint { query.append(("login_hint", loginHint)) }
        guard var components = URLComponents(string: "\(host.absoluteString)/\(tenantId)/oauth2/v2.0/authorize") else {
            throw AuthError.notConfigured("invalid tenant ID")
        }
        components.percentEncodedQuery = query.map { "\($0.0)=\(GraphClient.encode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { throw AuthError.notConfigured("invalid authorization URL") }
        return url
    }

    // MARK: - Token endpoint

    public func exchangeCode(
        _ code: String, redirectURI: String, codeVerifier: String, scopes: [String]
    ) async throws -> OAuthTokens {
        try await tokenRequest([
            ("client_id", clientId),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
            ("scope", Self.scopeString(scopes)),
        ], isRefresh: false)
    }

    /// `.interactionRequired` means the session is over (revoked, expired, password changed, …).
    public func refresh(_ refreshToken: String, scopes: [String]) async throws -> OAuthTokens {
        try await tokenRequest([
            ("client_id", clientId),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("scope", Self.scopeString(scopes)),
        ], isRefresh: true)
    }

    private func tokenRequest(_ form: [(String, String)], isRefresh: Bool) async throws -> OAuthTokens {
        var request = URLRequest(url: host.appendingPathComponent("\(tenantId)/oauth2/v2.0/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.map { "\($0.0)=\(GraphClient.encode($0.1))" }.joined(separator: "&").utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw AuthError.cancelled }
            throw AuthError.oauthFailure("Could not reach Microsoft Entra: \(error.localizedDescription)")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(data, status: response.statusCode, isRefresh: isRefresh)
        }
        guard let body = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.oauthFailure("Microsoft Entra returned a token response that could not be read.")
        }
        return OAuthTokens(
            accessToken: body.accessToken, refreshToken: body.refreshToken, idToken: body.idToken,
            expiresAt: now().addingTimeInterval(TimeInterval(body.expiresIn)))
    }

    static func mapError(_ data: Data, status: Int, isRefresh: Bool) -> AuthError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error ?? "http_\(status)"
        if isRefresh, ["invalid_grant", "interaction_required", "login_required", "consent_required"].contains(code) {
            return .interactionRequired
        }
        // Entra descriptions continue with trace and correlation IDs on later lines; keep the first.
        let summary = body?.description?.split(whereSeparator: \.isNewline).first.map(String.init)
        return .oauthFailure([code, summary].compactMap { $0 }.joined(separator: ": "))
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        // Entra sends a number; tolerate a numeric string.
        if let seconds = try? container.decode(Int.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decode(String.self, forKey: .expiresIn), let seconds = Int(text) {
            expiresIn = seconds
        } else {
            expiresIn = 3600
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case error
        case description = "error_description"
    }
}
