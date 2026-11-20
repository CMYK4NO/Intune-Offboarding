import Foundation

/// What Intune shows for a wipe or retire a few seconds after Graph accepted it (HTTP 204).
///
/// A 204 only means Graph took the request. On a real Mac, Intune answered 204 to a second wipe while an earlier
/// wipe was still pending, and created no new action for it. Reading the device back afterwards catches that.
public enum IntuneRegistration: String, Sendable, Equatable {
    /// A new entry for this action, started at or after the request, is in `deviceActionResults`.
    case registered
    /// The new entry, or the device's management state, already says the action failed.
    case failedInIntune
    /// Intune lists no new entry for this action: it may have ignored the request.
    case notRegistered
    /// The device record was already gone (404) when read back: for a wipe or retire this usually means the
    /// action ran and Intune removed the record (seen on a real Mac, then re-enrolled under a new id).
    case recordRemoved
    /// The device could not be read, or Intune returned no action list.
    case unverified
}

extension ManagedDevice {
    /// Clock difference allowed between this Mac and Intune when matching an entry to the request.
    static let registrationClockTolerance: TimeInterval = 120

    /// Did Intune record `action` (wipe or retire) that was sent at `sentAt`? Returns the outcome and a sentence for
    /// the administrator. Only entries that started after `sentAt` (minus the clock tolerance) count, so an older,
    /// still-pending entry is never taken as proof.
    public func registration(of action: OffboardingAction, sentAt: Date) -> (IntuneRegistration, String) {
        let name: String
        let failedState: Bool
        switch action {
        case .mdmWipe:
            name = "wipe"
            failedState = managementState == .wipeFailed
        case .retireDevice:
            name = "retire"
            failedState = managementState == .retireFailed
        default:
            return (.unverified, "")
        }
        guard let results = deviceActionResults else {
            return (.unverified, "Intune did not return the device's action list, so it could not be confirmed that "
                + "Intune registered the \(name). Check the device in Intune.")
        }
        let earliest = sentAt.addingTimeInterval(-Self.registrationClockTolerance)
        let fresh = results
            .filter { $0.actionName?.lowercased() == name && ($0.startDateTime ?? .distantPast) >= earliest }
            .max { ($0.startDateTime ?? .distantPast) < ($1.startDateTime ?? .distantPast) }
        if let fresh {
            if fresh.actionState?.lowercased() == "failed" || (failedState && !fresh.isInProgress) {
                return (.failedInIntune, "Intune registered the \(name) but already marked it failed: \(fresh.summary). "
                    + "Check the device in Intune.")
            }
            return (.registered, "Confirmed in Intune: \(fresh.summary).")
        }
        let latest = results.filter { $0.actionName?.lowercased() == name }
            .max { ($0.startDateTime ?? .distantPast) < ($1.startDateTime ?? .distantPast) }
        let last = latest.map { " The latest \(name) Intune lists is: \($0.summary)." } ?? ""
        return (.notRegistered, "WARNING: Intune shows no new \(name) for this device.\(last) Intune may have ignored "
            + "the request, for example because an earlier \(name) is still pending. Check the device in Intune before "
            + "trying again.")
    }
}
