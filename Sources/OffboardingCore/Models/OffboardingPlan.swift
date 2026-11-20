import Foundation

/// One action the administrator chose. Carries a fingerprint of the asset as it looked at review time,
/// so execution can be refused if the asset changed in the meantime.
public struct PlannedAction: Identifiable, Hashable, Sendable {
    public let asset: AssetID
    /// Display only.
    public let label: String
    public let action: OffboardingAction
    public let ownership: String?
    public let serialNumber: String?
    public let apiOperation: String
    public let fingerprint: Fingerprint
    /// The Windows "keep" switches of a wipe. `.fullWipe` for everything else. Part of the plan, so changing a switch
    /// changes the plan and clears the confirmation.
    public var wipeOptions: WipeOptions = .fullWipe
    /// Selective wipe only: the phone this device-tag group is on (`MAMHostDevice`), so Review can show one
    /// entry per phone. Display only; the action itself still targets this one device tag.
    public var hostID: String? = nil
    public var hostLabel: String? = nil

    public var id: AssetID { asset }

    public enum Fingerprint: Hashable, Sendable {
        case device(userId: String?, serialNumber: String?, deviceName: String?)
        /// Sorted registration ids on the device.
        case mamGroup(registrationIDs: [String])
    }
}

public extension OffboardingAction {
    /// The Graph operation behind an action, shown in the simulation preview and written to the audit log.
    /// All of them are Graph v1.0 operations. A wipe with Windows "keep" switches says so in the text.
    func apiDescription(assetID: String, wipeOptions: WipeOptions = .fullWipe) -> String {
        switch self {
        case .noAction: return "none"
        case .mdmWipe:
            let options = wipeOptions.isFullWipe ? "" : " (\(wipeOptions.summary))"
            return "POST /deviceManagement/managedDevices/\(assetID)/wipe\(options)"
        case .retireDevice: return "POST /deviceManagement/managedDevices/\(assetID)/retire"
        case .deleteIntuneRecord: return "DELETE /deviceManagement/managedDevices/\(assetID)"
        case .mamSelectiveWipe: return "POST /users/{userId}/wipeManagedAppRegistrationsByDeviceTag (deviceTag: \(assetID))"
        }
    }
}

/// Everything that would happen, in order. Only destructive choices appear here.
public struct OffboardingPlan: Equatable, Sendable {
    public let user: EntraUser
    public let mode: ExecutionMode
    public let actions: [PlannedAction]

    public var wipeCount: Int { actions.filter { $0.action == .mdmWipe }.count }
    public var retireCount: Int { actions.filter { $0.action == .retireDevice }.count }
    public var deleteCount: Int { actions.filter { $0.action == .deleteIntuneRecord }.count }
    /// Selective-wipe requests: one per device tag.
    public var selectiveWipeCount: Int { actions.filter { $0.action == .mamSelectiveWipe }.count }
    /// Phones those requests cover (several tags can be on one phone).
    public var selectiveWipeDeviceCount: Int {
        Set(actions.filter { $0.action == .mamSelectiveWipe }.map { $0.hostID ?? $0.asset.rawID }).count
    }
    public var deviceActions: [PlannedAction] { actions.filter { $0.asset.kind == .managedDevice } }
    public var mamActions: [PlannedAction] { actions.filter { $0.asset.kind == .mamRegistration } }

    /// Hard ceiling on device actions (Wipe, Retire, Delete) in one run. Offboarding is one user at a time with
    /// each asset chosen by hand, so a larger plan means something is wrong. It is enforced both in the
    /// confirmation policy and again by the executor, so no code path can wipe, retire or delete devices in bulk.
    /// Selective wipes are not counted: they only remove app data, and one user's apps can sit under many tags.
    public static let maxDestructiveActionsPerRun = 5

    /// Why this plan must never run, or nil. Checked before confirmation and again before executing.
    public var safetyViolation: String? {
        if deviceActions.count > Self.maxDestructiveActionsPerRun {
            return "This plan has \(deviceActions.count) device actions (wipe, retire or delete). At most \(Self.maxDestructiveActionsPerRun) are allowed in one run. Go back and choose fewer."
        }
        if Set(actions.map(\.asset)).count != actions.count {
            return "The plan lists the same asset more than once. Go back and review again."
        }
        return nil
    }
}

/// The administrator's per-asset choices. Every asset defaults to No Action; anything not set
/// explicitly stays No Action.
public struct OffboardingSelection: Equatable, Sendable {
    private var chosen: [AssetID: OffboardingAction] = [:]
    /// Windows wipe switches, kept only while the asset's action is Wipe Device. A full wipe is stored as "nothing".
    private var wipeOptionsChosen: [AssetID: WipeOptions] = [:]

    public init() {}

    public func action(for asset: AssetID) -> OffboardingAction { chosen[asset] ?? .default }

    public func wipeOptions(for asset: AssetID) -> WipeOptions { wipeOptionsChosen[asset] ?? .fullWipe }

    /// Ignores actions that do not apply to the asset kind (e.g. Wipe on a MAM group). Leaving Wipe Device
    /// forgets its switches, so choosing Wipe again always starts from a full wipe.
    public mutating func set(_ action: OffboardingAction, for asset: AssetID) {
        guard OffboardingAction.available(for: asset.kind).contains(action) else { return }
        chosen[asset] = action == .noAction ? nil : action
        if action != .mdmWipe { wipeOptionsChosen[asset] = nil }
    }

    /// Only applies while the asset's action is Wipe Device; otherwise it is ignored.
    public mutating func setWipeOptions(_ options: WipeOptions, for asset: AssetID) {
        guard chosen[asset] == .mdmWipe else { return }
        wipeOptionsChosen[asset] = options.isFullWipe ? nil : options
    }

    public mutating func clear() {
        chosen = [:]
        wipeOptionsChosen = [:]
    }

    /// Builds the plan from the assets currently discovered. A choice for an asset that is no longer
    /// in the lists is dropped rather than executed.
    public func makePlan(
        user: EntraUser, mode: ExecutionMode, devices: [ManagedDevice], mamGroups: [MAMDeviceGroup]
    ) -> OffboardingPlan {
        var planned: [PlannedAction] = []
        for device in devices {
            let asset = AssetID.managedDevice(device.id)
            let action = self.action(for: asset)
            guard action.isDestructive else { continue }
            // The "keep" switches exist for Windows only; any other device is always wiped completely.
            let options: WipeOptions = (action == .mdmWipe && device.isWindows) ? wipeOptions(for: asset) : .fullWipe
            planned.append(PlannedAction(
                asset: asset, label: device.deviceName ?? "Unnamed device", action: action,
                ownership: device.managedDeviceOwnerType?.displayName, serialNumber: device.serialNumber,
                apiOperation: action.apiDescription(assetID: device.id, wipeOptions: options),
                fingerprint: .device(userId: device.userId, serialNumber: device.serialNumber, deviceName: device.deviceName),
                wipeOptions: options))
        }
        // The phone each group is on, for labels only. Choices are still read and planned per group.
        let hostOf = Dictionary(MAMHostDevice.group(mamGroups).flatMap { host in host.groups.map { ($0.id, host) } },
                                uniquingKeysWith: { first, _ in first })
        for group in mamGroups {
            let asset = AssetID.mamDeviceGroup(group.id)
            let action = self.action(for: asset)
            guard action.isDestructive else { continue }
            // Selective wipe works on a device tag; a registration without one cannot be wiped this way.
            guard group.deviceTag != nil else { continue }
            let apps = group.appIdentifiers.joined(separator: ", ")
            let host = hostOf[group.id]
            let device = host.map { [$0.title, $0.osDescription].compactMap { $0 }.joined(separator: ", ") }
                ?? group.deviceName ?? "Unnamed device"
            var item = PlannedAction(
                asset: asset,
                label: "\(device)\(apps.isEmpty ? "" : " (\(apps))")",
                action: action, ownership: nil, serialNumber: nil,
                apiOperation: action.apiDescription(assetID: group.id),
                fingerprint: .mamGroup(registrationIDs: group.registrations.map(\.id).sorted()))
            item.hostID = host?.id
            item.hostLabel = device
            planned.append(item)
        }
        return OffboardingPlan(user: user, mode: mode, actions: planned)
    }
}
