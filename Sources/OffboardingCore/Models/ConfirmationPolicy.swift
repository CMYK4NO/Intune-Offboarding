import Foundation

/// What the administrator must do before a plan may run. Pure logic, so it is unit-tested.
///
/// - Every plan needs an explicit acknowledgement (the final confirmation).
/// - A plan containing an MDM Wipe additionally needs a typed phrase that includes the number of
///   devices.
/// - A plan containing any wipe, retire, record delete or selective wipe also gets a second confirmation alert
///   that lists the affected assets.
public struct ConfirmationPolicy: Equatable, Sendable {
    public let plan: OffboardingPlan

    public init(plan: OffboardingPlan) { self.plan = plan }

    /// Wipes only: these need the typed phrase.
    public var requiresStrongConfirmation: Bool {
        plan.actions.contains { $0.action.requiresStrongConfirmation }
    }

    /// Every destructive action (wipe, retire, record delete, selective wipe) gets the second confirmation alert.
    public var requiresSecondConfirmation: Bool { destructiveCount > 0 }

    /// Exact text the administrator must type, e.g. "WIPE 2". Nil when the plan has no wipe.
    public var requiredPhrase: String? {
        requiresStrongConfirmation ? "WIPE \(plan.wipeCount)" : nil
    }

    /// Typed text is compared exactly (after trimming whitespace); case matters on purpose.
    public func isSatisfied(acknowledged: Bool, typedPhrase: String) -> Bool {
        guard acknowledged, !plan.actions.isEmpty, plan.safetyViolation == nil else { return false }
        guard let required = requiredPhrase else { return true }
        return typedPhrase.trimmingCharacters(in: .whitespacesAndNewlines) == required
    }

    /// One line per asset that would be wiped, retired, deleted or selectively wiped, for the second confirmation.
    public var destructiveDeviceLines: [String] {
        plan.actions.compactMap { planned in
            switch planned.action {
            case .mdmWipe:
                let ownership = planned.ownership ?? "ownership unknown"
                // A full wipe of a device that is not corporate-owned erases someone's personal data: say so loudly.
                let flag = ownership.caseInsensitiveCompare("Corporate") == .orderedSame ? "" : " ⚠️ NOT CORPORATE-OWNED"
                // A wipe that keeps data must say so right where the administrator confirms it.
                let keeps = planned.wipeOptions.isFullWipe ? "" : " ⚠️ \(planned.wipeOptions.summary)"
                return "• Wipe: \(planned.label) (\(ownership), serial \(planned.serialNumber ?? "n/a"))\(flag)\(keeps)"
            case .retireDevice:
                return "• Retire: \(planned.label) (\(planned.ownership ?? "ownership unknown"), serial \(planned.serialNumber ?? "n/a"))"
            case .deleteIntuneRecord:
                return "• Delete record: \(planned.label) (\(planned.ownership ?? "ownership unknown"), serial \(planned.serialNumber ?? "n/a"))"
            case .mamSelectiveWipe:
                return "• Selective wipe (app data only): \(planned.label)"
            case .noAction:
                return nil
            }
        }
    }

    private var destructiveCount: Int { plan.wipeCount + plan.retireCount + plan.deleteCount + plan.selectiveWipeCount }

    /// Specific wording only when the plan holds a single kind of action; a mix gets the generic wording.
    private var kindCount: Int {
        [plan.wipeCount, plan.retireCount, plan.deleteCount, plan.selectiveWipeCount].filter { $0 > 0 }.count
    }

    /// Title and button of the second confirmation alert.
    public var alertTitle: String {
        guard kindCount <= 1 else { return "Confirm \(destructiveCount) destructive actions?" }
        if plan.retireCount > 0 { return "Retire \(plan.retireCount) device(s)?" }
        if plan.deleteCount > 0 { return "Delete \(plan.deleteCount) Intune record(s)?" }
        if plan.selectiveWipeCount > 0 { return "Selectively wipe app data on \(plan.selectiveWipeDeviceCount) device(s)?" }
        return "Wipe \(plan.wipeCount) device(s)?"
    }

    public var alertButtonTitle: String {
        if plan.mode == .simulation { return "Simulate" }
        guard kindCount <= 1 else { return "Run \(destructiveCount) actions" }
        if plan.retireCount > 0 { return "Retire \(plan.retireCount) device(s)" }
        if plan.deleteCount > 0 { return "Delete \(plan.deleteCount) record(s)" }
        if plan.selectiveWipeCount > 0 { return "Selective wipe \(plan.selectiveWipeDeviceCount) device(s)" }
        return "Wipe \(plan.wipeCount) device(s)"
    }

    /// Warning shown on the review screen and in the second confirmation.
    public var warning: String {
        let prefix = plan.mode == .simulation ? "SIMULATION: " : ""
        var parts: [String] = []
        if plan.wipeCount > 0 {
            let noun = plan.wipeCount == 1 ? "device" : "devices"
            parts.append("You are about to remotely wipe \(plan.wipeCount) \(noun). "
                + "This action can permanently erase data from these devices and cannot be undone.")
        }
        if plan.retireCount > 0 {
            let noun = plan.retireCount == 1 ? "device" : "devices"
            parts.append("You are about to retire \(plan.retireCount) \(noun). "
                + "Company data, apps and settings deployed by Intune and Intune management are removed when the device "
                + "next checks in; personal data stays and the device is not erased. Until it checks in, the retire stays "
                + "pending in Intune. This cannot be undone.")
        }
        if plan.deleteCount > 0 {
            let noun = plan.deleteCount == 1 ? "record" : "records"
            parts.append("You are about to delete \(plan.deleteCount) device \(noun) from Intune. "
                + "Intune's own Delete action sends a Retire command to Apple, macOS and Windows devices "
                + "(and a Wipe to corporate-owned Android), so the device may lose company data and management. "
                + "This cannot be undone.")
        }
        if plan.selectiveWipeCount > 0 {
            let noun = plan.selectiveWipeDeviceCount == 1 ? "device" : "devices"
            let requests = plan.selectiveWipeCount == plan.selectiveWipeDeviceCount ? ""
                : " (\(plan.selectiveWipeCount) requests to Intune, one per app group)"
            parts.append("You are about to selectively wipe app data on \(plan.selectiveWipeDeviceCount) \(noun)\(requests). "
                + "This removes organisation data from apps protected by Intune App Protection; the device itself "
                + "is not erased. It cannot be undone.")
        }
        if plan.deviceActions.contains(where: { !$0.wipeOptions.isFullWipe }) {
            parts.append("At least one wipe is set to keep data on the device (see the lines below). That device is not fully erased.")
        }
        if parts.isEmpty { parts.append("You are about to change \(plan.actions.count) item(s) in Intune.") }
        return prefix + parts.joined(separator: " ")
    }
}
