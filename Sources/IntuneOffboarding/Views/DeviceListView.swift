import OffboardingCore
import SwiftUI

/// The user's Intune-managed devices with a per-device action choice (default: No Action).
struct DeviceListView: View {
    let user: EntraUser
    let state: DiscoveryState<DeviceDiscoveryResult>
    let onRetry: () -> Void
    let action: (AssetID) -> OffboardingAction
    let wipeOptions: (AssetID) -> WipeOptions
    let locked: Bool
    let onSelect: (AssetID, OffboardingAction) -> Void
    let onWipeOptions: (AssetID, WipeOptions) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MDM DEVICES").font(.headline).foregroundStyle(.secondary)
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView("Discovering Intune devices…")
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Retry", action: onRetry)
            case .loaded(let result):
                if !result.excluded.isEmpty {
                    Label("\(result.excluded.count) device(s) returned by Intune could not be tied to this user and were left out.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    DisclosureGroup("Show the devices that were left out") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(result.excluded) { device in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text([device.deviceName, device.serialNumber.map { "serial \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                        .fontWeight(.semibold)
                                    Text(DeviceDiscoveryResult.exclusionReason(for: device, user: user)).font(.footnote)
                                    Text("Intune device ID: \(device.id)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    }
                }
                if result.devices.isEmpty {
                    Text("No Intune-managed devices are associated with this user.").foregroundStyle(.secondary)
                } else {
                    Text("\(result.devices.count) device(s)").font(.footnote).foregroundStyle(.secondary)
                    ForEach(result.devices) { device in
                        DeviceRow(
                            device: device, action: action(.managedDevice(device.id)),
                            wipeOptions: wipeOptions(.managedDevice(device.id)),
                            locked: locked, onSelect: onSelect, onWipeOptions: onWipeOptions)
                    }
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: ManagedDevice
    let action: OffboardingAction
    let wipeOptions: WipeOptions
    let locked: Bool
    let onSelect: (AssetID, OffboardingAction) -> Void
    let onWipeOptions: (AssetID, WipeOptions) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                details
                Divider()
                ActionPicker(asset: .managedDevice(device.id), choices: allowedActions, current: action,
                             locked: locked, onSelect: onSelect)
                if let pending = device.offboardingActionsInProgress.first {
                    Label("\(pending.summary). Actions that would clash with it are hidden until Intune finishes it.",
                          systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if device.managementState == .wipeFailed || device.managementState == .retireFailed {
                    Label("Intune marked the last \(device.managementState == .wipeFailed ? "wipe" : "retire") as failed (state "
                          + "\(device.managementState?.rawValue ?? "")). It can be sent again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if device.isWindows && action == .mdmWipe {
                    windowsWipeOptions
                }
            }
        }
    }

    /// Hides Wipe/Retire/Delete while they would clash with an action Intune has not finished. The current choice
    /// stays visible so the administrator sees it; the validator and the executor refuse it anyway.
    private var allowedActions: [OffboardingAction] {
        OffboardingAction.available(for: .managedDevice).filter { $0 == action || device.blockingReason(for: $0) == nil }
    }

    /// Windows-only switches of the wipe. Both off (the default) is a full wipe.
    private var windowsWipeOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Windows wipe options").font(.caption).foregroundStyle(.secondary)
            Toggle("Keep enrollment data", isOn: wipeBinding(\.keepEnrollmentData))
            Toggle("Keep user data", isOn: wipeBinding(\.keepUserData))
            Text("Leave both off to erase everything. Each switch keeps data on a device that is being offboarded.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(locked)
        .opacity(locked ? 0.6 : 1)
    }

    private func wipeBinding(_ keyPath: WritableKeyPath<WipeOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { wipeOptions[keyPath: keyPath] },
            set: { value in
                var updated = wipeOptions
                updated[keyPath: keyPath] = value
                onWipeOptions(.managedDevice(device.id), updated)
            })
    }

    private var details: some View {
        DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    detail("Serial number", device.serialNumber)
                    detail("Manufacturer / model", [device.manufacturer, device.model].compactMap { $0 }.joined(separator: " "))
                    detail("OS", [device.operatingSystem, device.osVersion].compactMap { $0 }.joined(separator: " "))
                    detail("Management state", device.managementState?.rawValue)
                    detail("Management agent", device.managementAgent)
                    detail("Enrolled", device.enrolledDateTime?.formatted(date: .abbreviated, time: .shortened))
                    detail("Last check-in", device.lastSyncDateTime?.formatted(date: .abbreviated, time: .shortened))
                    detail("Recent remote actions",
                           device.recentActions.isEmpty ? nil : device.recentActions.map(\.summary).joined(separator: "; "))
                    detail("Primary user", device.userPrincipalName ?? device.userDisplayName)
                    detail("Intune device ID", device.id)
                    detail("Entra device ID", device.azureADDeviceId)
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.deviceName ?? "Unnamed device").fontWeight(.semibold)
                        Text([device.operatingSystem, device.serialNumber.map { "Serial \($0)" }]
                            .compactMap { $0 }.joined(separator: "  ·  "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    badge(ownership.0, color: ownership.1)
                    badge(compliance.0, color: compliance.1)
                }
            }
    }

    private var ownership: (String, Color) {
        switch device.managedDeviceOwnerType {
        case .some(.company): return ("Corporate", .blue)
        case .some(.personal): return ("Personal", .purple)
        default: return ("Ownership unknown", .gray)
        }
    }

    private var compliance: (String, Color) {
        switch device.complianceState {
        case .some(.compliant): return ("Compliant", .green)
        case .some(.noncompliant): return ("Non-compliant", .red)
        case .some(.inGracePeriod): return ("Grace period", .orange)
        default: return ("Compliance: \(device.complianceState?.rawValue ?? "unknown")", .gray)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func detail(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—").textSelection(.enabled)
        }
        .font(.callout)
    }
}
