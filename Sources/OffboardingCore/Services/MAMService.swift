import Foundation

public struct MAMDiscoveryResult: Equatable, Sendable {
    /// Registrations whose `userId` matches the resolved user.
    public let registrations: [MAMRegistration]
    /// The same registrations grouped per device, for display and (later) selective wipe.
    public let groups: [MAMDeviceGroup]
    /// Returned by Graph but not tied to this user (different or missing `userId`); never offered for actions.
    public let excluded: [MAMRegistration]
    /// True when the beta device details (Entra device ID, model) could not be read; apps are then shown per device tag.
    public let deviceDetailsUnavailable: Bool

    /// The groups merged per phone, for display and selection. Actions still run per group.
    public var hosts: [MAMHostDevice] { MAMHostDevice.group(groups) }

    public init(registrations: [MAMRegistration], groups: [MAMDeviceGroup], excluded: [MAMRegistration],
                deviceDetailsUnavailable: Bool = false) {
        self.registrations = registrations
        self.groups = groups
        self.excluded = excluded
        self.deviceDetailsUnavailable = deviceDetailsUnavailable
    }
}

public protocol MAMDiscovering: Sendable {
    func discoverRegistrations(for user: EntraUser) async throws -> MAMDiscoveryResult
}

public enum MAMDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case invalidUserID

    public var errorDescription: String? {
        "The resolved user has an unexpected ID format. App-protection discovery was stopped."
    }
}

/// Read-only MAM / App Protection discovery.
///
/// Query: GET /v1.0/users/{id}/managedAppRegistrations (delegated DeviceManagementApps.Read.All).
/// No `$select`: the registration type is polymorphic (iOS/Android/…), so the default projection is used
/// and every property is optional in the model. Like device discovery, each registration's `userId`
/// is checked against the resolved user.
public struct MAMService: MAMDiscovering {
    private let graph: GraphClient
    private let details: MAMDeviceDetailsProviding?
    private let log = AppLogger(category: .workflow)

    /// `details` adds the beta-only Entra device ID and model. Leave it nil where only v1.0 data is wanted
    /// (the re-read before a selective wipe uses none, so the destructive path never depends on beta).
    public init(graph: GraphClient, details: MAMDeviceDetailsProviding? = nil) {
        self.graph = graph
        self.details = details
    }

    public func discoverRegistrations(for user: EntraUser) async throws -> MAMDiscoveryResult {
        guard user.hasPathSafeID else { throw MAMDiscoveryError.invalidUserID }
        let returned: [MAMRegistration] = try await graph.getAll("/users/\(user.id)/managedAppRegistrations")

        var seen = Set<String>()
        var matched: [MAMRegistration] = []
        var excluded: [MAMRegistration] = []
        for registration in returned where seen.insert(registration.id).inserted {
            if registration.userId?.caseInsensitiveCompare(user.id) == .orderedSame {
                matched.append(registration)
            } else {
                excluded.append(registration)
            }
        }
        var detailsUnavailable = false
        if let details {
            do {
                // Matched by registration id only; a detail never adds, removes or reassigns a registration.
                let fetched = try await details.deviceDetails(forUserID: user.id)
                let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in matched.indices {
                    guard let detail = byID[matched[index].id] else { continue }
                    matched[index].azureADDeviceId = detail.azureADDeviceId
                    matched[index].deviceModel = detail.deviceModel
                    matched[index].deviceManufacturer = detail.deviceManufacturer
                }
            } catch {
                detailsUnavailable = true
                log.warning("Beta app-protection device details unavailable, showing per device tag: \(error.localizedDescription)")
            }
        }
        let groups = MAMDeviceGroup.group(matched)
        log.info("Discovered \(matched.count) MAM registration(s) on \(groups.count) device tag(s) for user \(user.id), excluded \(excluded.count)")
        return MAMDiscoveryResult(registrations: matched, groups: groups, excluded: excluded,
                                  deviceDetailsUnavailable: detailsUnavailable)
    }
}
