import Foundation

/// Microsoft Entra device object (Graph v1.0 `device`).
///
/// Deliberately separate from `ManagedDevice`: the Intune record and the Entra object are
/// different entities. They are linked only via `ManagedDevice.azureADDeviceId == EntraDevice.deviceId`
/// (note: `deviceId`, not the object `id`).
public struct EntraDevice: Codable, Identifiable, Hashable, Sendable {
    /// Directory object id.
    public let id: String
    /// Device id, matches `ManagedDevice.azureADDeviceId`.
    public let deviceId: String?
    public let displayName: String?
    public let accountEnabled: Bool?
    public let operatingSystem: String?
    public let operatingSystemVersion: String?
    public let trustType: String?
    public let isCompliant: Bool?
    public let isManaged: Bool?
    public let approximateLastSignInDateTime: Date?
}
