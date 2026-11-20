import Foundation

/// Public-client configuration. Application (client) ID and tenant ID are identifiers, not
/// secrets. There is NO client secret: this is a native public client using Authorization Code + PKCE
/// with a loopback redirect (`http://localhost`).
///
/// The two IDs are not part of the source: the administrator enters them in Settings (`AppSettings`).
struct AuthConfiguration: Equatable {
    let clientId: String
    let tenantId: String

    /// Nil unless BOTH values are GUIDs. The tenant must be the GUID, not a domain name: the sign-in compares it
    /// with the `tid` claim of the identity token to make sure the right tenant answered.
    init?(clientId: String, tenantId: String) {
        guard let client = Self.normalizedGUID(clientId), let tenant = Self.normalizedGUID(tenantId) else { return nil }
        self.clientId = client
        self.tenantId = tenant
    }

    /// Trimmed, lower-case GUID, or nil when `value` is not one.
    static func normalizedGUID(_ value: String) -> String? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased()
    }

    /// Delegated, READ-ONLY scopes for user lookup and discovery. Each *.All delegated permission
    /// needs admin consent in the tenant.
    static let discoveryScopes = [
        "User.Read",
        "User.ReadBasic.All", // id, displayName, userPrincipalName only (no accountEnabled)
        "DeviceManagementManagedDevices.Read.All",
        "DeviceManagementApps.Read.All", // MAM / App Protection registrations (Phase 5)
    ]

    /// Write scopes, added per destructive phase. The v1.0 wipe page lists PrivilegedOperations.All as its only delegated permission.
    /// Delete (Phase 9) is documented with ReadWrite.All as its only delegated permission. Selective wipe (Phase 10) re-verifies its own.
    static let writeScopes = [
        "DeviceManagementManagedDevices.PrivilegedOperations.All", // MDM Wipe (Phase 8)
        "DeviceManagementManagedDevices.ReadWrite.All", // Delete Intune device record (Phase 9)
        "DeviceManagementApps.ReadWrite.All", // MAM selective wipe (Phase 10)
    ]

    /// Requested at sign-in so the administrator consents to everything once. The signed-in
    /// administrator's own Intune role still decides what is actually allowed (delegated flow).
    static let signInScopes = discoveryScopes + writeScopes
}

/// Where the two IDs live: the app's preferences (`UserDefaults`). They are identifiers, not secrets, so no keychain.
/// An organisation can also push them with a configuration profile (preference domain = the bundle identifier,
/// keys `EntraClientId` and `EntraTenantId`); managed values win and the Settings fields become read-only.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let clientId = "EntraClientId"
        static let tenantId = "EntraTenantId"
    }

    @Published private(set) var clientId: String
    @Published private(set) var tenantId: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clientId = defaults.string(forKey: Key.clientId) ?? ""
        tenantId = defaults.string(forKey: Key.tenantId) ?? ""
    }

    /// The validated configuration, or nil while a value is missing or not a GUID.
    var configuration: AuthConfiguration? { AuthConfiguration(clientId: clientId, tenantId: tenantId) }
    var isConfigured: Bool { configuration != nil }

    /// True when a configuration profile sets either value; it cannot be changed from inside the app.
    var isManaged: Bool { defaults.objectIsForced(forKey: Key.clientId) || defaults.objectIsForced(forKey: Key.tenantId) }

    /// Stores the values when both are valid GUIDs. Returns false (and stores nothing) otherwise.
    @discardableResult
    func save(clientId: String, tenantId: String) -> Bool {
        guard !isManaged, let config = AuthConfiguration(clientId: clientId, tenantId: tenantId) else { return false }
        defaults.set(config.clientId, forKey: Key.clientId)
        defaults.set(config.tenantId, forKey: Key.tenantId)
        self.clientId = config.clientId
        self.tenantId = config.tenantId
        return true
    }
}
