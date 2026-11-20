import Foundation

/// Whether operations really call Graph. The app starts in `.simulation`; production must be
/// switched on deliberately (Phase 7+).
public enum ExecutionMode: String, Codable, Sendable {
    case simulation
    case production
}

public enum AssetKind: String, Codable, Sendable {
    case managedDevice
    /// Any MAM / App Protection asset (a registration or a per-device group of registrations).
    case mamRegistration
}

/// Stable identity of an asset, always a Graph/Intune id, never a display name.
public enum AssetID: Hashable, Codable, Sendable {
    case managedDevice(String)
    case mamRegistration(String)
    /// All registrations on one device (grouped by device tag); selective wipe acts on the group.
    case mamDeviceGroup(String)

    public var kind: AssetKind {
        switch self {
        case .managedDevice: return .managedDevice
        case .mamRegistration, .mamDeviceGroup: return .mamRegistration
        }
    }

    public var rawID: String {
        switch self {
        case .managedDevice(let id), .mamRegistration(let id), .mamDeviceGroup(let id): return id
        }
    }
}

/// What the administrator may choose for an asset. Wipe, Retire and Delete are deliberately separate cases;
/// nothing in the code base may chain one into the other implicitly.
public enum OffboardingAction: String, Codable, CaseIterable, Sendable {
    case noAction
    /// Intune remote action: erases the physical device.
    case mdmWipe
    /// Intune remote action: removes company data and Intune management at the next check-in. Personal data stays;
    /// the device is not erased. Separate from both Wipe and Delete.
    case retireDevice
    /// Deletes the managed-device record in Intune (DELETE managedDevices/{id}). Not a wipe, but Intune may retire the device.
    case deleteIntuneRecord
    /// Removes organisational app data protected by App Protection; no full device wipe.
    case mamSelectiveWipe

    public static let `default`: OffboardingAction = .noAction

    public var isDestructive: Bool { self != .noAction }

    /// MDM wipe is the only action that needs the stronger second confirmation.
    public var requiresStrongConfirmation: Bool { self == .mdmWipe }

    public var title: String {
        switch self {
        case .noAction: return "No Action"
        case .mdmWipe: return "Wipe Device"
        case .retireDevice: return "Retire Device"
        case .deleteIntuneRecord: return "Delete from Intune"
        case .mamSelectiveWipe: return "Selective Wipe"
        }
    }

    /// Actions that make sense for a kind of asset (the UI offers only these).
    public static func available(for kind: AssetKind) -> [OffboardingAction] {
        switch kind {
        case .managedDevice: return [.noAction, .mdmWipe, .retireDevice, .deleteIntuneRecord]
        case .mamRegistration: return [.noAction, .mamSelectiveWipe]
        }
    }
}
