import Foundation

public struct DeviceDiscoveryResult: Equatable, Sendable {
    /// Devices whose `userId` matches the resolved user. Only these are offered for offboarding.
    public let devices: [ManagedDevice]
    /// Devices Graph returned that could NOT be tied to the user (different or missing `userId`).
    /// Shown as a warning, never offered for actions.
    public let excluded: [ManagedDevice]

    public init(devices: [ManagedDevice], excluded: [ManagedDevice]) {
        self.devices = devices
        self.excluded = excluded
    }
}

public protocol DeviceDiscovering: Sendable {
    func discoverDevices(for user: EntraUser) async throws -> DeviceDiscoveryResult
}

public enum DeviceDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case invalidUserID

    public var errorDescription: String? {
        "The resolved user has an unexpected ID format. Device discovery was stopped."
    }
}

/// Read-only Intune MDM discovery.
///
/// Two steps (delegated DeviceManagementManagedDevices.Read.All):
///  1. GET /v1.0/users/{id}/managedDevices?$select=id lists the CANDIDATE device ids for the user.
///  2. GET /v1.0/deviceManagement/managedDevices/{id}?$select=… reads each candidate in full. This is the same
///     read the executor repeats before any wipe or delete.
///
/// The user fields (`userId`, `userPrincipalName`) come back empty from the per-user list on a real tenant, so the
/// association is checked on the full record, never on the list.
///
/// The per-user path is used instead of `deviceManagement/managedDevices?$filter=userId eq '…'`
/// because Microsoft documents `$filter` only for specific managedDevice properties and `userId`
/// is not documented among them; an ignored filter would return other people's devices.
/// As a second safeguard every returned device's `userId` is checked against the resolved user.
public struct IntuneDeviceService: DeviceDiscovering {
    private let graph: GraphClient
    private let log = AppLogger(category: .workflow)

    public init(graph: GraphClient) { self.graph = graph }

    public func discoverDevices(for user: EntraUser) async throws -> DeviceDiscoveryResult {
        guard user.hasPathSafeID else { throw DeviceDiscoveryError.invalidUserID }
        let listed: [ManagedDevice] = try await graph.getAll(
            "/users/\(user.id)/managedDevices", query: [("$select", "id")])

        var seen = Set<String>() // devices are identified by Intune id only
        var matched: [ManagedDevice] = []
        var excluded: [ManagedDevice] = []
        for candidate in listed where seen.insert(candidate.id).inserted {
            // Full record by id. A device that vanished since the list is skipped; any other error is shown.
            let device: ManagedDevice
            do {
                guard IntuneDeviceActionService.isPathSafe(candidate.id) else { excluded.append(candidate); continue }
                device = try await graph.get(
                    "/deviceManagement/managedDevices/\(candidate.id)",
                    query: [("$select", ManagedDevice.graphSelect.joined(separator: ","))])
            } catch GraphError.notFound {
                log.info("Managed device \(candidate.id) no longer exists, skipped")
                continue
            }
            if device.userId?.caseInsensitiveCompare(user.id) == .orderedSame {
                matched.append(device)
            } else {
                excluded.append(device)
            }
        }
        matched.sort { lhs, rhs in
            let l = (lhs.deviceName ?? "").lowercased(), r = (rhs.deviceName ?? "").lowercased()
            return l == r ? lhs.id < rhs.id : l < r
        }
        log.info("Discovered \(matched.count) managed device(s) for user \(user.id), excluded \(excluded.count)")
        return DeviceDiscoveryResult(devices: matched, excluded: excluded)
    }
}

public extension DeviceDiscoveryResult {
    /// Why Intune returned a device for this user's query but it was not offered for actions. Display only:
    /// it never makes a device eligible, and execution still requires `userId` to equal the user's ID.
    static func exclusionReason(for device: ManagedDevice, user: EntraUser) -> String {
        let shownUser = device.userPrincipalName ?? device.userDisplayName ?? "unknown"
        guard let id = device.userId, !id.isEmpty else {
            return "Intune returned no user ID for this device (primary user shown as: \(shownUser))."
        }
        if id.allSatisfy({ $0 == "0" || $0 == "-" }) {
            return "The device has no primary user assigned (user ID is all zeros)."
        }
        let upnMatches = device.userPrincipalName?.caseInsensitiveCompare(user.userPrincipalName) == .orderedSame
        return "The device's user ID is \(id), not \(user.id)"
            + (upnMatches ? ", although its user name matches \(user.userPrincipalName)." : " (user: \(shownUser)).")
    }
}
