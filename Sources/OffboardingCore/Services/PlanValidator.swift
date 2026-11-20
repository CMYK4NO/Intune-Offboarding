import Foundation

public enum PlanValidationIssue: Equatable, LocalizedError, Sendable {
    case userChanged
    case deviceMissing(String)
    case deviceNoLongerAssociated(String)
    case deviceChanged(String)
    case mamGroupMissing(String)
    case mamGroupChanged(String)
    case lookupFailed(String)
    /// Production runs are refused unless the administrator confirms their identity with a fresh sign-in.
    case reauthenticationFailed(String)
    /// A wipe, retire or delete Intune has not finished yet blocks a new one on the same device.
    case actionInProgress(String, String)
    /// Production runs are refused when the audit trail cannot be written.
    case auditUnavailable

    public var errorDescription: String? {
        switch self {
        case .userChanged:
            return "The user now resolves to a different identity than the one you reviewed."
        case .deviceMissing(let label):
            return "\(label): this device no longer exists in Intune."
        case .deviceNoLongerAssociated(let label):
            return "\(label): this device is no longer associated with the reviewed user."
        case .deviceChanged(let label):
            return "\(label): the device's name, serial number or primary user changed since review."
        case .mamGroupMissing(let label):
            return "\(label): these app-protection registrations no longer exist."
        case .mamGroupChanged(let label):
            return "\(label): the set of app-protection registrations on this device changed since review."
        case .actionInProgress(let label, let reason):
            return "\(label): \(reason)"
        case .reauthenticationFailed(let detail):
            return "Identity not confirmed, so nothing was sent. \(detail)"
        case .auditUnavailable:
            return "The audit log could not be written, so nothing was sent. Production runs are refused without an audit trail. Check that the Logs folder is writable."
        case .lookupFailed(let detail):
            return "Validation could not be completed: \(detail)"
        }
    }
}

/// Re-reads the user and every planned asset (read-only) and compares them with what the admin
/// reviewed. Any difference blocks execution: the admin must go back and review again.
public struct PlanValidator: Sendable {
    private let users: UserResolving
    private let devices: DeviceDiscovering
    private let mam: MAMDiscovering

    public init(users: UserResolving, devices: DeviceDiscovering, mam: MAMDiscovering) {
        self.users = users
        self.devices = devices
        self.mam = mam
    }

    /// Empty result means the plan is still valid.
    public func validate(_ plan: OffboardingPlan) async -> [PlanValidationIssue] {
        do {
            let user = try await users.resolve(upn: plan.user.userPrincipalName)
            guard user.id == plan.user.id else { return [.userChanged] }

            var issues: [PlanValidationIssue] = []
            if !plan.deviceActions.isEmpty {
                let result = try await devices.discoverDevices(for: user)
                let current = Dictionary(result.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let excluded = Set(result.excluded.map(\.id))
                for planned in plan.deviceActions {
                    guard case .managedDevice(let id) = planned.asset else { continue }
                    if let device = current[id] {
                        let now = PlannedAction.Fingerprint.device(
                            userId: device.userId, serialNumber: device.serialNumber, deviceName: device.deviceName)
                        if now != planned.fingerprint { issues.append(.deviceChanged(planned.label)) }
                        if let reason = device.blockingReason(for: planned.action) {
                            issues.append(.actionInProgress(planned.label, reason))
                        }
                    } else if excluded.contains(id) {
                        issues.append(.deviceNoLongerAssociated(planned.label))
                    } else {
                        issues.append(.deviceMissing(planned.label))
                    }
                }
            }
            if !plan.mamActions.isEmpty {
                let result = try await mam.discoverRegistrations(for: user)
                let current = Dictionary(result.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for planned in plan.mamActions {
                    guard case .mamDeviceGroup(let id) = planned.asset else { continue }
                    if let group = current[id] {
                        let now = PlannedAction.Fingerprint.mamGroup(registrationIDs: group.registrations.map(\.id).sorted())
                        if now != planned.fingerprint { issues.append(.mamGroupChanged(planned.label)) }
                    } else {
                        issues.append(.mamGroupMissing(planned.label))
                    }
                }
            }
            return issues
        } catch {
            return [.lookupFailed(error.localizedDescription)]
        }
    }
}
