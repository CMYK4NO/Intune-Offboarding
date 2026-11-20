import AppKit
import OffboardingCore

/// OAuth 2.0 Authorization Code flow with PKCE against Microsoft Entra ID, using the default browser
/// and a loopback redirect (`http://localhost:<port>`).
///
/// - Native public client: there is no client secret. Delegated permissions only.
/// - Tokens live in memory for the session and are never written to disk, logged or shown. The
///   administrator signs in again after quitting the app, which suits a destructive-action tool and
///   needs no keychain (so it works for an app that is not signed with a developer identity).
/// - Interactive sign-in happens only from `signIn()`, never implicitly in the middle of an operation.
@MainActor
final class AuthenticationService: ObservableObject, AccessTokenProviding, AuthVerifying, Reauthenticating {
    @Published private(set) var state: AuthState = .signedOut

    private let settings: AppSettings
    /// Taken from Settings when sign-in starts and kept for the whole session, so a refresh can never go to a
    /// different tenant or app than the sign-in did. The Settings fields are locked while a session is open.
    private var config: AuthConfiguration?
    private var oauth: EntraOAuthClient?
    private var tokens: OAuthTokens?
    private var session: AdminSession?
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<OAuthTokens, Error>?
    private var reauthTask: Task<AdminSession, Error>?
    private let log = AppLogger(category: .auth)

    /// Renew the access token when less than this is left, so a request never starts with a token about to expire.
    private static let refreshMargin: TimeInterval = 300
    private static let signInTimeout: TimeInterval = 300

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    /// Opens the default browser for sign-in. Safe to call repeatedly; ignored while in progress.
    func signIn() async {
        if case .signingIn = state { return }
        guard let configuration = settings.configuration else {
            state = .failed(AuthError.notConfigured("enter the Application (client) ID and Directory (tenant) ID in Settings.").localizedDescription)
            return
        }
        config = configuration
        oauth = EntraOAuthClient(tenantId: configuration.tenantId, clientId: configuration.clientId)
        state = .signingIn
        let task = Task { await self.performSignIn() }
        signInTask = task
        await task.value
        signInTask = nil
    }

    /// Abandons a sign-in that is waiting for the browser.
    func cancelSignIn() { signInTask?.cancel() }

    /// A valid Graph access token WITHOUT showing UI. Throws `.interactionRequired` when the session is over.
    /// One token carries every consented scope, so `scopes` is not used to pick a token.
    func accessToken(for scopes: [String]) async throws -> String {
        try await currentTokens(forceRefresh: false).accessToken
    }

    /// Call before every destructive operation: forces a refresh round-trip to Entra, so a
    /// revoked or expired session is detected now rather than half-way through execution.
    func verifyStillAuthenticated(scopes: [String]) async throws -> AdminSession {
        _ = try await currentTokens(forceRefresh: true)
        guard let session else { throw AuthError.notSignedIn }
        return session
    }

    func signOut() async {
        signInTask?.cancel()
        reauthTask?.cancel()
        clearSession()
        log.info("Signed out")
    }

    // MARK: - Confirm identity before a production run

    /// Fresh browser sign-in with `prompt=login`, so the administrator must enter credentials again (and MFA when
    /// Conditional Access asks for it). The result counts only if it is the SAME account in the same tenant as the
    /// current session; its tokens then replace the current ones. Anything else throws and nothing is run.
    func reauthenticate() async throws -> AdminSession {
        guard let owner = session else { throw AuthError.notSignedIn }
        guard reauthTask == nil else {
            throw AuthError.oauthFailure("A confirmation sign-in is already open in the browser.")
        }
        let task = Task { () throws -> AdminSession in
            let (received, claims) = try await self.interactiveSignIn(prompt: "login", loginHint: owner.username)
            let confirmed = AdminSession(
                accountId: claims.objectId, username: claims.username,
                displayName: claims.name, tenantId: claims.tenantId)
            guard confirmed.isSameAccount(as: owner) else {
                self.log.warning("Confirmation sign-in used a different account; production run refused")
                throw AuthError.oauthFailure(
                    "You confirmed as \(claims.username), but this session belongs to \(owner.username).")
            }
            // Signed out (or in as someone else) while the browser was open: the new tokens are discarded.
            guard self.session == owner else { throw AuthError.notSignedIn }
            self.tokens = received
            self.log.info("Identity confirmed for \(owner.username) before a production run")
            return owner
        }
        reauthTask = task
        defer { reauthTask = nil }
        do {
            return try await task.value
        } catch {
            throw Self.map(error)
        }
    }

    func cancelReauthentication() { reauthTask?.cancel() }

    // MARK: - Browser sign-in

    private func performSignIn() async {
        do {
            let (received, claims) = try await interactiveSignIn(prompt: "select_account", loginHint: nil)
            tokens = received
            let session = AdminSession(
                accountId: claims.objectId, username: claims.username,
                displayName: claims.name, tenantId: claims.tenantId)
            self.session = session
            state = .signedIn(session)
            log.info("Signed in as \(session.username) (tenant \(session.tenantId))")
        } catch {
            let mapped = Self.map(error)
            clearSession(state: mapped == .cancelled ? .signedOut : .failed(mapped.localizedDescription))
            log.warning("Sign-in did not complete: \(mapped.localizedDescription)")
        }
    }

    /// Authorization Code + PKCE in the default browser with a loopback redirect. Returns the tokens and the
    /// validated identity (audience, tenant, nonce of THIS request); does not change the session.
    private func interactiveSignIn(prompt: String, loginHint: String?) async throws -> (OAuthTokens, AdminClaims) {
        let pkce = PKCE.generate()
        let stateValue = SecureRandom.token()
        let nonce = SecureRandom.token()
        let scopes = AuthConfiguration.signInScopes
        guard let oauth, let config else {
            throw AuthError.notConfigured("enter the Application (client) ID and Directory (tenant) ID in Settings.")
        }

        let listener = LoopbackRedirectListener()
        let redirect = try await listener.receiveCode(expectedState: stateValue, timeout: Self.signInTimeout) { port in
            do {
                let url = try oauth.authorizationURL(
                    redirectURI: "http://localhost:\(port)", scopes: scopes,
                    state: stateValue, nonce: nonce, codeChallenge: pkce.challenge,
                    prompt: prompt, loginHint: loginHint)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } catch {
                // Cannot happen with a valid tenant ID; the listener's timeout ends the attempt.
            }
        }

        // Bring the app back in front of the browser so the administrator sees what happens next.
        NSApp.activate(ignoringOtherApps: true)
        let received = try await oauth.exchangeCode(
            redirect.code, redirectURI: "http://localhost:\(redirect.port)",
            codeVerifier: pkce.verifier, scopes: scopes)
        guard let idToken = received.idToken else {
            throw AuthError.oauthFailure("The sign-in response did not include an identity token.")
        }
        let claims = try IDToken.validate(idToken, clientId: config.clientId, tenantId: config.tenantId, nonce: nonce)
        return (received, claims)
    }

    // MARK: - Token lifecycle

    private func currentTokens(forceRefresh: Bool) async throws -> OAuthTokens {
        // The session the refresh belongs to. If it changes while the request is out (sign-out, or sign-in as
        // someone else), the result is thrown away so one account's tokens never end up under another session.
        guard let tokens, let owner = session, let oauth else { throw AuthError.notSignedIn }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > Self.refreshMargin { return tokens }
        guard let refreshToken = tokens.refreshToken else {
            clearSession()
            throw AuthError.interactionRequired
        }
        // Concurrent callers share one refresh request.
        if let refreshTask {
            let shared = try await refreshTask.value
            guard session == owner else { throw AuthError.notSignedIn }
            return shared
        }
        let task = Task { try await oauth.refresh(refreshToken, scopes: AuthConfiguration.signInScopes) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            // Session ended or changed while the refresh was in flight: drop the new tokens.
            guard session == owner else { throw AuthError.notSignedIn }
            let merged = OAuthTokens(
                accessToken: renewed.accessToken,
                refreshToken: renewed.refreshToken ?? refreshToken, // Entra may rotate it
                idToken: tokens.idToken, expiresAt: renewed.expiresAt)
            self.tokens = merged
            return merged
        } catch {
            let mapped = Self.map(error)
            // Session over: surface it, but never end a newer session that started meanwhile.
            if mapped == .interactionRequired, session == owner { clearSession() }
            throw mapped
        }
    }

    private func clearSession(state newState: AuthState = .signedOut) {
        tokens = nil
        session = nil
        oauth = nil
        config = nil
        refreshTask?.cancel()
        refreshTask = nil
        state = newState
    }

    private static func map(_ error: Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .oauthFailure(error.localizedDescription)
    }
}
