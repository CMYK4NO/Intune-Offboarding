import Foundation

/// One entry of `managedDevice.deviceActionResults` (Graph v1.0, read-only): a remote action Intune issued to the
/// device and its state. Graph returns it only when a device is read by id with the property in `$select`.
/// Decoded leniently: a malformed entry becomes empty fields and never breaks device discovery.
public struct DeviceActionResult: Codable, Hashable, Sendable {
    public let actionName: String?
    /// Documented values: none, pending, canceled, active, done, failed, notSupported. Kept raw.
    public let actionState: String?
    public let startDateTime: Date?
    public let lastUpdatedDateTime: Date?

    private enum CodingKeys: String, CodingKey { case actionName, actionState, startDateTime, lastUpdatedDateTime }

    public init(actionName: String?, actionState: String?, startDateTime: Date? = nil, lastUpdatedDateTime: Date? = nil) {
        self.actionName = actionName
        self.actionState = actionState
        self.startDateTime = startDateTime
        self.lastUpdatedDateTime = lastUpdatedDateTime
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        actionName = (try? c?.decodeIfPresent(String.self, forKey: .actionName)) ?? nil
        actionState = (try? c?.decodeIfPresent(String.self, forKey: .actionState)) ?? nil
        startDateTime = (try? c?.decodeIfPresent(Date.self, forKey: .startDateTime)) ?? nil
        lastUpdatedDateTime = (try? c?.decodeIfPresent(Date.self, forKey: .lastUpdatedDateTime)) ?? nil
    }

    /// Still waiting for, or being carried out on, the device.
    public var isInProgress: Bool { ["pending", "active"].contains(actionState?.lowercased() ?? "") }

    /// "Wipe pending since 18 Nov 2026 at 02:30" (date in the Mac's time zone).
    public var summary: String {
        let name = actionName.flatMap { $0.isEmpty ? nil : $0 } ?? "Action"
        let state = actionState ?? "unknown"
        let when = (lastUpdatedDateTime ?? startDateTime).map { " (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
        let since = isInProgress ? startDateTime.map { " since \($0.formatted(date: .abbreviated, time: .shortened))" } : nil
        return "\(name.prefix(1).uppercased())\(name.dropFirst()) \(state)\(since ?? when)"
    }
}

extension ManagedDevice {
    /// Wipe, retire or delete that Intune has not finished on this device, from `deviceActionResults` or, as a
    /// second source, `managementState` (wipePending, retireIssued, …). Lower-cased action names.
    public var offboardingActionsInProgress: [(name: String, summary: String)] {
        var found: [(name: String, summary: String)] = []
        for result in deviceActionResults ?? [] where result.isInProgress {
            let name = result.actionName?.lowercased() ?? ""
            // Intune can leave the action entry "pending" after it has already marked the device wipeFailed or
            // retireFailed (seen on a real Mac). Intune's own failure state wins: a failed action blocks nothing.
            if name == "wipe" && managementState == .wipeFailed { continue }
            if name == "retire" && managementState == .retireFailed { continue }
            if ["wipe", "retire", "delete"].contains(name) { found.append((name, result.summary)) }
        }
        let fromState: String?
        switch managementState {
        case .wipePending, .wipeIssued: fromState = "wipe"
        case .retirePending, .retireIssued: fromState = "retire"
        case .deletePending: fromState = "delete"
        default: fromState = nil
        }
        if let fromState, !found.contains(where: { $0.name == fromState }) {
            found.append((fromState, "Intune management state: \(managementState?.rawValue ?? fromState)"))
        }
        return found
    }

    /// Why `action` must not be sent now, or nil when nothing blocks it.
    /// - Wipe and Retire: blocked while any wipe, retire or delete is still in progress on the device.
    /// - Delete: blocked only while a WIPE is in progress (deleting the record would drop the wipe, so the device
    ///   might never be erased). A pending retire does not block it: Delete also retires.
    public func blockingReason(for action: OffboardingAction) -> String? {
        let inProgress = offboardingActionsInProgress
        let blocking: [(name: String, summary: String)]
        switch action {
        case .mdmWipe, .retireDevice: blocking = inProgress
        case .deleteIntuneRecord: blocking = inProgress.filter { $0.name == "wipe" }
        case .noAction, .mamSelectiveWipe: return nil
        }
        guard let first = blocking.first else { return nil }
        // Intune cannot cancel a wipe. A record that never checks in again keeps it pending until the record is deleted.
        return "\(first.summary). Wait until Intune finishes it before sending \(action.title). Intune cannot cancel a "
            + "pending action; if this record is stale (the device enrolled again under a new record), delete it in Intune."
    }

    /// Up to three most recent remote actions, newest first, for display.
    public var recentActions: [DeviceActionResult] {
        let sorted = (deviceActionResults ?? []).sorted {
            ($0.lastUpdatedDateTime ?? $0.startDateTime ?? .distantPast) > ($1.lastUpdatedDateTime ?? $1.startDateTime ?? .distantPast)
        }
        return Array(sorted.prefix(3))
    }
}
