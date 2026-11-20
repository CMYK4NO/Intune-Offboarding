import OffboardingCore
import SwiftUI

/// Identity card. When `onConfirm` is set, shows the explicit "this is the right person" step
/// that must happen before any asset is displayed.
struct UserSummaryView: View {
    let user: EntraUser
    var onConfirm: (() -> Void)?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                row("Display name", user.displayName ?? "—")
                row("UPN", user.userPrincipalName)
                row("Entra user ID", user.id)
                HStack(alignment: .firstTextBaseline) {
                    Text("Account").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    accountState
                }
                if let onConfirm {
                    Divider()
                    Text("Verify the name, UPN and ID above before continuing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("This is the correct user — continue", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder private var accountState: some View {
        switch user.accountEnabled {
        case .some(true): Label("Enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false): Label("Disabled", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        case .none: Text("Not available with current permissions").foregroundStyle(.secondary)
        }
    }
}
