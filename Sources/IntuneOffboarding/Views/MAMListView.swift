import OffboardingCore
import SwiftUI

/// Read-only inventory of App Protection (MAM) registrations, one entry per phone or tablet.
/// Kept apart from the MDM list: a registration here does not imply an MDM device above.
struct MAMListView: View {
    let state: DiscoveryState<MAMDiscoveryResult>
    let onRetry: () -> Void
    let action: (MAMHostDevice) -> OffboardingAction
    let isMixed: (MAMHostDevice) -> Bool
    let locked: Bool
    let onSelect: (MAMHostDevice, OffboardingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MAM / APP PROTECTION").font(.headline).foregroundStyle(.secondary)
            switch state {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView("Discovering app-protection registrations…")
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Button("Retry", action: onRetry)
            case .loaded(let result):
                if !result.excluded.isEmpty {
                    Label("\(result.excluded.count) registration(s) returned by Intune could not be tied to this user and were left out.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if result.deviceDetailsUnavailable {
                    Label("Device model and Entra device ID could not be read, so apps are listed per app group and one phone may appear more than once.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                let hosts = result.hosts
                if hosts.isEmpty {
                    Text("No app-protection registrations are associated with this user.").foregroundStyle(.secondary)
                } else {
                    Text("\(result.registrations.count) app registration(s) on \(hosts.count) device(s). These are separate from the MDM devices above.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(hosts) { host in
                        MAMHostRow(host: host, action: action(host), mixed: isMixed(host), locked: locked, onSelect: onSelect)
                    }
                }
            }
        }
    }
}

private struct MAMHostRow: View {
    let host: MAMHostDevice
    let action: OffboardingAction
    let mixed: Bool
    let locked: Bool
    let onSelect: (MAMHostDevice, OffboardingAction) -> Void

    private var untaggedCount: Int { host.groups.filter { $0.deviceTag == nil }.flatMap(\.registrations).count }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                details
                Divider()
                // The asset only tells the picker which actions apply; the choice goes to every group on the phone.
                ActionPicker(asset: .mamDeviceGroup(host.id),
                             choices: host.wipeableGroups.isEmpty ? [.noAction] : nil,
                             current: action, locked: locked,
                             onSelect: { _, chosen in onSelect(host, chosen) })
                if mixed {
                    Label("Some app groups on this device are selected and some are not (the list was reloaded). Choose the action again.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if host.wipeableGroups.count > 1 {
                    Text("Selective wipe sends \(host.wipeableGroups.count) requests to Intune, one per app group on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if untaggedCount > 0 {
                    Text(host.wipeableGroups.isEmpty
                         ? "No device tag: selective wipe is not possible for these registrations."
                         : "\(untaggedCount) app(s) have no device tag and are not included in a selective wipe.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var details: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                detail("Device name", host.deviceName)
                detail("Model", [host.deviceManufacturer, host.deviceModel].compactMap { $0 }.joined(separator: " "))
                detail("OS version", host.platformVersion)
                detail("Device type", host.deviceType)
                detail("Entra device ID", host.entraDeviceId)
                detail("Last sync", host.lastSync?.formatted(date: .abbreviated, time: .shortened))
                ForEach(host.groups) { group in
                    Divider()
                    detail("App group (device tag)", group.deviceTag ?? "none (registration is listed on its own)")
                    ForEach(group.registrations) { registration in
                        detail(registration.appIdentifier?.displayValue ?? "Unknown app",
                               [registration.applicationVersion.map { "v\($0)" },
                                registration.lastSyncDateTime.map { "synced \($0.formatted(date: .abbreviated, time: .shortened))" },
                                "registration \(registration.id)"].compactMap { $0 }.joined(separator: "  ·  "))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.title).fontWeight(.semibold)
                    Text([host.osDescription, host.deviceName.flatMap { $0 == host.title ? nil : $0 }]
                            .compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(host.appIdentifiers.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if host.isFlagged { badge("Flagged", color: .red) }
                badge("\(host.registrations.count) app(s)", color: .orange)
            }
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
