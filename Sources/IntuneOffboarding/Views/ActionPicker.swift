import OffboardingCore
import SwiftUI

extension OffboardingAction {
    /// Visual language from the project spec: red wipe, purple retire, red/orange delete record, orange MAM
    /// selective wipe, gray no action.
    var tint: Color {
        switch self {
        case .noAction: return .gray
        case .mdmWipe: return .red
        case .retireDevice: return .purple
        case .deleteIntuneRecord: return Color(red: 0.9, green: 0.3, blue: 0.1)
        case .mamSelectiveWipe: return .orange
        }
    }

    /// Short explanation shown next to the choice, so Wipe and Delete can never be confused.
    var explanation: String {
        switch self {
        case .noAction: return "Leave untouched"
        case .mdmWipe: return "Erases the device through an Intune remote action"
        case .retireDevice: return "Removes company data and Intune management at next check-in; the device is not erased"
        case .deleteIntuneRecord: return "Deletes the device record from Intune; for Apple and Windows devices Intune also sends a Retire"
        case .mamSelectiveWipe: return "Removes organisation app data only; no full device wipe"
        }
    }
}

/// Per-asset action choice. Every asset starts at No Action.
struct ActionPicker: View {
    let asset: AssetID
    /// Actions offered; defaults to everything that applies to the asset kind.
    var choices: [OffboardingAction]?
    let current: OffboardingAction
    let locked: Bool
    let onSelect: (AssetID, OffboardingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action").font(.caption).foregroundStyle(.secondary)
            ForEach(choices ?? OffboardingAction.available(for: asset.kind), id: \.self) { action in
                Button {
                    onSelect(asset, action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: current == action ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(current == action ? action.tint : .secondary)
                        Text(action.title).fontWeight(current == action ? .semibold : .regular)
                            .foregroundStyle(action == .noAction ? Color.primary : action.tint)
                        Text(action.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.title). \(action.explanation)")
                .accessibilityAddTraits(current == action ? [.isSelected] : [])
                .disabled(locked)
            }
        }
        .opacity(locked ? 0.6 : 1)
    }
}
