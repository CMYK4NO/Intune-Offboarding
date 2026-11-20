import OffboardingCore
import SwiftUI

/// Sidebar: signed-in administrator on top, workflow pages in fixed order, mode switch at the bottom.
struct SidebarView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel
    let session: AdminSession
    let onSignOut: () -> Void
    let onEnableProduction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            account
            Divider()
            List(selection: selection) {
                Section("Offboarding") {
                    row(.user)
                    row(.devices)
                    row(.appProtection)
                    row(.review, badge: viewModel.pendingPlan?.actions.count)
                    row(.results)
                }
                Section("History") {
                    row(.auditLog)
                }
            }
            .listStyle(.sidebar)
            // While a run is validating or executing nothing in the sidebar can be used.
            .disabled(viewModel.isBusy)
            Divider()
            modeControl
        }
    }

    private var selection: Binding<SidebarPage?> {
        // The List can write its selection back while SwiftUI is still updating views, and publishing a change
        // then is undefined behaviour. No-op writes are ignored; real changes are applied on the next run-loop turn.
        Binding(get: { viewModel.page }, set: { newPage in
            guard let newPage, newPage != viewModel.page else { return }
            DispatchQueue.main.async { viewModel.navigate(to: newPage) }
        })
    }

    private func row(_ page: SidebarPage, badge: Int? = nil) -> some View {
        Label(page.title, systemImage: page.systemImage)
            .badge(badge ?? 0)
            .tag(page)
            .disabled(!viewModel.isAvailable(page))
            .accessibilityHint(viewModel.isAvailable(page) ? "" : "Not available yet")
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.displayName ?? session.username).fontWeight(.semibold)
            Text(session.username).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Tenant \(session.tenantId)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Sign out", action: onSignOut)
                .controlSize(.small)
                .disabled(viewModel.isBusy)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder private var modeControl: some View {
        if viewModel.canUseProduction {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.mode == .simulation {
                    Button("Enable production mode…", action: onEnableProduction)
                        .disabled(!canChangeMode)
                } else {
                    Button("Back to simulation") { viewModel.setMode(.simulation) }
                        .disabled(!canChangeMode)
                }
                if !canChangeMode {
                    Text("The mode can be changed while choosing actions for a confirmed user.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    /// Same rule as `OffboardingViewModel.setMode`: only while choosing actions.
    private var canChangeMode: Bool {
        !viewModel.isBusy && viewModel.confirmedUser != nil && !viewModel.isSelectionLocked
    }
}
