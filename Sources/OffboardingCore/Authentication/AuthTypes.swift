import Foundation

/// Source of Graph access tokens. `GraphClient` depends only on this protocol, so it never
/// touches passwords or secrets, and tests can inject a fake.
public protocol AccessTokenProviding: Sendable {
    /// Returns a valid access token WITHOUT showing UI. Throws `AuthError.interactionRequired`
    /// when the user must sign in again; callers must not pop sign-in mid-operation.
    func accessToken(for scopes: [String]) async throws -> String
}

/// Forces a round-trip to Entra to prove the administrator's session is still valid. Called before
/// destructive operations so a revoked or expired session is caught before anything is sent.
public protocol AuthVerifying: Sendable {
    func verifyStillAuthenticated(scopes: [String]) async throws -> AdminSession
}

/// The signed-in administrator. Contains no token material.
public struct AdminSession: Equatable, Sendable {
    /// Entra object ID of the administrator (`oid` claim).
    public let accountId: String
    /// UPN of the administrator.
    public let username: String
    public let displayName: String?
    /// Entra tenant ID the token was issued for.
    public let tenantId: String

    public init(accountId: String, username: String, displayName: String?, tenantId: String) {
        self.accountId = accountId
        self.username = username
        self.displayName = displayName
        self.tenantId = tenantId
    }
}

extension AdminSession {
    /// Same Entra account in the same tenant (object id and tenant id; the UPN can change, these cannot).
    public func isSameAccount(as other: AdminSession) -> Bool {
        !accountId.isEmpty
            && accountId.caseInsensitiveCompare(other.accountId) == .orderedSame
            && tenantId.caseInsensitiveCompare(other.tenantId) == .orderedSame
    }
}

/// Proves that the person at the keyboard is the signed-in administrator, with a fresh interactive sign-in that
/// must enter credentials again. Called right before a production run. Throws unless the new sign-in is the SAME
/// account in the same tenant; nothing may be sent when it throws.
public protocol Reauthenticating: Sendable {
    func reauthenticate() async throws -> AdminSession
    func cancelReauthentication() async
}

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn(AdminSession)
    case failed(String)
}

public enum AuthError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured(String)
    case notSignedIn
    case interactionRequired
    case cancelled
    case wrongTenant(expected: String, actual: String)
    case oauthFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail):
            return "Authentication is not configured correctly: \(detail)"
        case .notSignedIn:
            return "You are not signed in. Sign in with your administrator account."
        case .interactionRequired:
            return "Your sign-in has expired or needs to be refreshed. Please sign in again."
        case .cancelled:
            return "Sign-in was cancelled."
        case .wrongTenant(let expected, let actual):
            return "Signed in to the wrong tenant (\(actual)). This tool only works with tenant \(expected)."
        case .oauthFailure(let detail):
            return "Microsoft Entra sign-in failed: \(detail)"
        }
    }
}
