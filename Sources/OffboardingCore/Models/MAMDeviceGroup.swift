import Foundation

/// App-protection registrations that share one device tag. This is the unit Intune's selective wipe works on
/// (`wipeManagedAppRegistrationsByDeviceTag`), so plans, validation and execution stay per group.
/// Grouped by `deviceTag`; a registration without a tag stays on its own, because grouping on name would
/// merge unrelated devices. Several groups can sit on one phone: see `MAMHostDevice`.
public struct MAMDeviceGroup: Identifiable, Hashable, Sendable {
    /// Device tag, or "registration:<id>" when the registration has none.
    public let id: String
    public let deviceTag: String?
    public let deviceName: String?
    public let deviceType: String?
    /// From the most recently synced registration, so a stale app does not show an old OS version.
    public let platformVersion: String?
    /// Beta-only details (see `MAMRegistration`). Nil when unknown, or when the group's registrations disagree.
    public let entraDeviceId: String?
    public let deviceModel: String?
    public let deviceManufacturer: String?
    public let registrations: [MAMRegistration]

    public var appIdentifiers: [String] {
        registrations.compactMap { $0.appIdentifier?.displayValue }.sorted()
    }
    public var isFlagged: Bool { registrations.contains { $0.isFlagged } }
    public var lastSync: Date? { registrations.compactMap(\.lastSyncDateTime).max() }

    public static func group(_ registrations: [MAMRegistration]) -> [MAMDeviceGroup] {
        var buckets: [String: [MAMRegistration]] = [:]
        var order: [String] = []
        for registration in registrations {
            let key = registration.deviceTag.flatMap { $0.isEmpty ? nil : $0 } ?? "registration:\(registration.id)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(registration)
        }
        let groups = order.map { key -> MAMDeviceGroup in
            let regs = buckets[key] ?? []
            // Newest sync first: its device name, model and OS version are the current ones.
            let newest = regs.sorted { ($0.lastSyncDateTime ?? .distantPast) > ($1.lastSyncDateTime ?? .distantPast) }
            func newestValue(_ value: (MAMRegistration) -> String?) -> String? {
                newest.compactMap(value).first { !$0.isEmpty }
            }
            let entraIDs = Set(regs.compactMap { $0.azureADDeviceId?.lowercased() }.filter { !$0.isEmpty })
            return MAMDeviceGroup(
                id: key,
                deviceTag: key.hasPrefix("registration:") ? nil : key,
                deviceName: newestValue { $0.deviceName },
                deviceType: newestValue { $0.deviceType },
                platformVersion: newestValue { $0.platformVersion },
                entraDeviceId: entraIDs.count == 1 ? entraIDs.first : nil,
                deviceModel: newestValue { $0.deviceModel },
                deviceManufacturer: newestValue { $0.deviceManufacturer },
                registrations: regs.sorted { $0.id < $1.id })
        }
        return groups.sorted {
            let l = ($0.deviceName ?? "").lowercased(), r = ($1.deviceName ?? "").lowercased()
            return l == r ? $0.id < $1.id : l < r
        }
    }
}
