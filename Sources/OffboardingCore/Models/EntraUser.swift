import Foundation

/// Microsoft Entra user (Graph v1.0 `user`). Resolved from the UPN before any Intune query.
public struct EntraUser: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String?
    public let userPrincipalName: String
    public let accountEnabled: Bool?

    public init(id: String, displayName: String?, userPrincipalName: String, accountEnabled: Bool?) {
        self.id = id
        self.displayName = displayName
        self.userPrincipalName = userPrincipalName
        self.accountEnabled = accountEnabled
    }

    /// The id is placed in URL paths, so only GUID-like characters are accepted.
    public var hasPathSafeID: Bool {
        GraphID.isSafe(id)
    }

    /// Properties to request with `$select` (Graph returns only a small default set otherwise).
    /// `accountEnabled` is deliberately absent: it is outside the User.ReadBasic.All profile, so
    /// the field stays nil unless a broader permission is used.
    public static let graphSelect = ["id", "displayName", "userPrincipalName"]
}
