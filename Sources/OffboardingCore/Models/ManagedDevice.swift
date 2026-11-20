import Foundation

/// Intune managed device (Graph v1.0 `deviceManagement/managedDevices`, resource type `managedDevice`).
///
/// Identity rule: a device is identified ONLY by `id` (the Intune managed device id).
/// `deviceName` is display-only; two devices can share a name.
public struct ManagedDevice: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// Entra user id of the primary user.
    public let userId: String?
    public let deviceName: String?
    public let managedDeviceOwnerType: OwnerType?
    public let enrolledDateTime: Date?
    public let lastSyncDateTime: Date?
    public let operatingSystem: String?
    public let osVersion: String?
    public let complianceState: ComplianceState?
    public let managementState: ManagementState?
    /// Kept as a raw string: the enum is large and display-only here.
    public let managementAgent: String?
    /// Links to `EntraDevice.deviceId`.
    public let azureADDeviceId: String?
    public let serialNumber: String?
    public let manufacturer: String?
    public let model: String?
    public let userPrincipalName: String?
    public let userDisplayName: String?
    /// Remote actions Intune issued to the device and their state (v1.0, read-only). Only filled when the device
    /// is read by id with the property in `$select`; nil from list calls.
    public let deviceActionResults: [DeviceActionResult]?

    public enum OwnerType: String, LenientStringEnum, Hashable {
        case unknown, company, personal
        public static var fallback: OwnerType { .unknown }

        public var displayName: String {
            switch self {
            case .company: return "Corporate"
            case .personal: return "Personal"
            case .unknown: return "Unknown"
            }
        }
    }

    public enum ComplianceState: String, LenientStringEnum, Hashable {
        case unknown, compliant, noncompliant, conflict, error, inGracePeriod, configManager
        public static var fallback: ComplianceState { .unknown }
    }

    /// Notably includes the in-flight remote-action states (`wipePending`, `wipeIssued`, …),
    /// which Phase 8 uses to tell "wipe request submitted" apart from "wipe completed".
    public enum ManagementState: String, LenientStringEnum, Hashable {
        case managed, retirePending, retireFailed, wipePending, wipeFailed, unhealthy
        case deletePending, retireIssued, wipeIssued, wipeCanceled, retireCanceled, discovered
        case unrecognized
        public static var fallback: ManagementState { .unrecognized }
    }

    /// Graph reports "Windows" for Windows devices. Decides only whether the Windows-specific options (wipe "keep"
    /// switches) apply; it never makes a device eligible for anything.
    public var isWindows: Bool { operatingSystem?.lowercased().hasPrefix("windows") == true }

    /// Properties to request with `$select` when reading a device by id (`deviceActionResults` is returned only there).
    public static let graphSelect = [
        "id", "userId", "deviceName", "managedDeviceOwnerType", "enrolledDateTime",
        "lastSyncDateTime", "operatingSystem", "osVersion", "complianceState", "managementState",
        "managementAgent", "azureADDeviceId", "serialNumber", "manufacturer", "model",
        "userPrincipalName", "userDisplayName", "deviceActionResults",
    ]
}
