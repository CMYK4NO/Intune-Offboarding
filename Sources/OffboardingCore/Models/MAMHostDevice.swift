import Foundation

/// One phone or tablet as the administrator thinks of it: every app-protection group (device tag) whose
/// registrations report the same Entra device ID. Apps on one phone can register under different tags
/// (Slack and Zoom often do), which made one iPhone look like several.
///
/// Display and selection only. Selective wipe still runs per device tag (`MAMDeviceGroup`), one request
/// per tag, so a phone with three tags gets three requests, each validated and audited on its own.
///
/// Merging is conservative: only groups with exactly one, identical Entra device ID merge. A group with no
/// Entra device ID (beta details unavailable, or Microsoft left it empty) stays a device of its own.
public struct MAMHostDevice: Identifiable, Hashable, Sendable {
    /// "entra:<id>" or the single group's id.
    public let id: String
    public let entraDeviceId: String?
    public let groups: [MAMDeviceGroup]

    public var registrations: [MAMRegistration] { groups.flatMap(\.registrations) }
    /// Groups that can be selectively wiped (they have a device tag).
    public var wipeableGroups: [MAMDeviceGroup] { groups.filter { $0.deviceTag != nil } }
    public var appIdentifiers: [String] { groups.flatMap(\.appIdentifiers).sorted() }
    public var isFlagged: Bool { groups.contains { $0.isFlagged } }
    public var lastSync: Date? { groups.compactMap(\.lastSync).max() }

    /// The group that synced last describes the device as it is now.
    private var newest: MAMDeviceGroup? {
        groups.max { ($0.lastSync ?? .distantPast) < ($1.lastSync ?? .distantPast) }
    }
    public var deviceName: String? { newest?.deviceName ?? groups.lazy.compactMap(\.deviceName).first }
    public var deviceType: String? { newest?.deviceType ?? groups.lazy.compactMap(\.deviceType).first }
    public var platformVersion: String? { newest?.platformVersion ?? groups.lazy.compactMap(\.platformVersion).first }
    public var deviceModel: String? { newest?.deviceModel ?? groups.lazy.compactMap(\.deviceModel).first }
    public var deviceManufacturer: String? { newest?.deviceManufacturer ?? groups.lazy.compactMap(\.deviceManufacturer).first }

    /// "iPhone 17 Pro Max", "Samsung SM-A155F", or the device name when the model is unknown.
    public var title: String {
        if let model = deviceModel, !model.isEmpty {
            if let name = DeviceModelNames.marketingName(for: model) { return name }
            // "Apple iPhone99,9" reads oddly; other makers' model codes need the brand ("Samsung SM-A155F").
            if let maker = deviceManufacturer, !maker.isEmpty, maker.lowercased() != "apple",
               !model.lowercased().hasPrefix(maker.lowercased()) {
                return "\(maker.prefix(1).uppercased())\(maker.dropFirst()) \(model)"
            }
            return model
        }
        return deviceName ?? "Unnamed device"
    }

    /// "iOS 27.2.1" style line, from what is known.
    public var osDescription: String? {
        guard let version = platformVersion, !version.isEmpty else { return nil }
        let os = deviceType.flatMap { Self.osName(for: $0) } ?? platformFromApps
        return [os, version].compactMap { $0 }.joined(separator: " ")
    }

    /// Android registrations report the model in `deviceType`, so the OS comes from the app identifier instead:
    /// Android apps have a `packageId`, iOS apps a `bundleId`. Nil if the apps disagree or say nothing.
    private var platformFromApps: String? {
        let platforms = Set(registrations.compactMap { r -> String? in
            if r.appIdentifier?.packageId != nil { return "Android" }
            if r.appIdentifier?.bundleId != nil { return "iOS" }
            return nil
        })
        return platforms.count == 1 ? platforms.first : nil
    }

    /// Graph's `deviceType` for iOS registrations is the device class ("iPhone", "iPad"), not the OS name.
    private static func osName(for deviceType: String) -> String? {
        let type = deviceType.lowercased()
        if type.hasPrefix("iphone") || type.hasPrefix("ipod") { return "iOS" }
        if type.hasPrefix("ipad") { return "iPadOS" }
        if type.contains("android") { return "Android" }
        return nil
    }

    public static func group(_ groups: [MAMDeviceGroup]) -> [MAMHostDevice] {
        var buckets: [String: [MAMDeviceGroup]] = [:]
        var order: [String] = []
        for group in groups {
            let key = group.entraDeviceId.map { "entra:\($0)" } ?? group.id
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(group)
        }
        let hosts = order.map { key in
            MAMHostDevice(id: key, entraDeviceId: key.hasPrefix("entra:") ? String(key.dropFirst(6)) : nil,
                          groups: (buckets[key] ?? []).sorted { $0.id < $1.id })
        }
        return hosts.sorted {
            let l = $0.title.lowercased(), r = $1.title.lowercased()
            return l == r ? $0.id < $1.id : l < r
        }
    }
}

/// Apple model identifiers ("iPhone18,2") to marketing names. Display only: an unknown identifier is shown
/// as it is, so a missing entry is never wrong, only less friendly. New iPhones each September need a line.
/// Source: Apple identifier lists (everymac.com, appledb), checked November 2026.
public enum DeviceModelNames {
    static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd gen)", "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air", "iPhone18,5": "iPhone 17e",
    ]

    public static func marketingName(for identifier: String) -> String? {
        names[identifier.trimmingCharacters(in: .whitespaces)]
    }
}
