import Foundation

/// The write side of MAM / App Protection offboarding. Kept apart from `MAMDiscovering` (read-only) so a
/// discovery-only component can never be handed a wipe capability.
public protocol MAMActionPerforming: Sendable {
    /// Re-reads the user's app-protection registrations, grouped per device (used to re-verify before a wipe).
    func currentGroups(for user: EntraUser) async throws -> [MAMDeviceGroup]
    /// Submits a selective wipe of every registration the user has on the device with this tag.
    /// Returns the HTTP status (204 = accepted, NOT completed).
    func selectiveWipe(userID: String, deviceTag: String) async throws -> Int
}

/// Body of `POST /users/{id}/wipeManagedAppRegistrationsByDeviceTag` (Graph v1.0).
struct DeviceTagBody: Encodable {
    let deviceTag: String
}

/// v1.0 operations:
/// - GET  /users/{id}/managedAppRegistrations (read, via `MAMDiscovering`; delegated DeviceManagementApps.Read.All)
/// - POST /users/{id}/wipeManagedAppRegistrationsByDeviceTag  body {"deviceTag": "…"} → 204 No Content
///   (delegated DeviceManagementApps.ReadWrite.All, the only permission Microsoft lists for it)
///
/// "Selective wipe" removes organisation app data that Intune App Protection manages, without erasing the
/// device. The action works on a device tag, so it acts on the whole group of registrations that share the
/// tag, which is exactly how `MAMDeviceGroup` groups them.
public struct MAMActionService: MAMActionPerforming {
    private let graph: GraphClient
    private let discovery: MAMDiscovering
    private let log = AppLogger(category: .workflow)

    public init(graph: GraphClient, discovery: MAMDiscovering) {
        self.graph = graph
        self.discovery = discovery
    }

    public func currentGroups(for user: EntraUser) async throws -> [MAMDeviceGroup] {
        try await discovery.discoverRegistrations(for: user).groups
    }

    public func selectiveWipe(userID: String, deviceTag: String) async throws -> Int {
        guard Self.isPathSafe(userID), !deviceTag.isEmpty else { throw DeviceActionError.invalidDeviceID }
        log.info("Submitting MAM selective wipe for user \(userID)") // the tag is not logged
        return try await graph.post("/users/\(userID)/wipeManagedAppRegistrationsByDeviceTag",
                                    body: DeviceTagBody(deviceTag: deviceTag))
    }

    /// The user id is placed in a URL path, so only GUID-like characters are accepted.
    static func isPathSafe(_ id: String) -> Bool {
        GraphID.isSafe(id)
    }
}
