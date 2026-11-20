import OffboardingCore
import SwiftUI

/// Shell: mode banner on top; signed out → sign-in screen; signed in → sidebar with the workflow pages.
struct RootView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel
    @EnvironmentObject private var auth: AuthenticationService
    @State private var confirmProduction = false

    var body: some View {
        VStack(spacing: 0) {
            ModeBanner(mode: viewModel.mode)
            switch auth.state {
            case .signedIn(let session):
                NavigationSplitView {
                    SidebarView(session: session, onSignOut: { Task { await auth.signOut() } },
                                onEnableProduction: { confirmProduction = true })
                        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
                } detail: {
                    detail
                }
            case .signedOut, .signingIn, .failed:
                AuthenticationView()
            }
        }
        .alert("Enable production mode?", isPresented: $confirmProduction) {
            Button("Cancel", role: .cancel) {}
            Button("Enable production", role: .destructive) { viewModel.setMode(.production) }
        } message: {
            Text("Actions you confirm will be executed against Intune. A device wipe can permanently erase the device and cannot be undone. Production mode switches back to simulation when you change user or sign out.")
        }
        .onChange(of: auth.state) { state in
            if state == .signedOut { viewModel.reset() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch viewModel.page {
        case .user:
            if let user = viewModel.confirmedUser {
                selectedUser(user)
            } else {
                SearchView()
            }
        case .devices:
            if let user = viewModel.confirmedUser {
                assetPage {
                    DeviceListView(
                        user: user,
                        state: viewModel.deviceDiscovery,
                        onRetry: { viewModel.retryDeviceDiscovery() },
                        action: { viewModel.action(for: $0) },
                        wipeOptions: { viewModel.wipeOptions(for: $0) },
                        locked: viewModel.isSelectionLocked,
                        onSelect: { viewModel.setAction($1, for: $0) },
                        onWipeOptions: { viewModel.setWipeOptions($1, for: $0) })
                }
            }
        case .appProtection:
            assetPage {
                MAMListView(
                    state: viewModel.mamDiscovery,
                    onRetry: { viewModel.retryMAMDiscovery() },
                    action: { viewModel.action(for: $0) },
                    isMixed: { viewModel.hasMixedActions($0) },
                    locked: viewModel.isSelectionLocked,
                    onSelect: { viewModel.setAction($1, for: $0) })
            }
        case .review:
            if let plan = viewModel.plan {
                ReviewView(plan: plan)
            } else {
                noActionsSelected
            }
        case .results:
            if let result = viewModel.result { ResultsView(result: result) }
        case .auditLog:
            AuditLogView()
        }
    }

    /// Review page before any destructive action is chosen.
    private var noActionsSelected: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OFFBOARDING REVIEW").font(.title2).fontWeight(.bold)
            Label("Every asset is set to No Action, so there is nothing to review. Choose actions on the Devices or App protection page and they appear here at once.",
                  systemImage: "checklist")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The confirmed identity, read-only. Changing user discards the whole workflow.
    private func selectedUser(_ user: EntraUser) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected user").font(.title2).fontWeight(.semibold)
            UserSummaryView(user: user)
            Button("Change user") { viewModel.changeUser() }
                .disabled(viewModel.isBusy)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Scrollable asset content plus the selection bar. The pickers lock themselves outside the selection step.
    private func assetPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.isSelectionLocked && !viewModel.isBusy {
                        Label("The selection is locked after a run. Use “Back to selection” on the Results page to change it.",
                              systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                if let plan = viewModel.pendingPlan {
                    Text("\(plan.actions.count) action(s) selected. The Review page is up to date.").foregroundStyle(.secondary)
                } else {
                    Text("Every asset is set to No Action").foregroundStyle(.secondary)
                }
                Button("Open Review") { viewModel.navigate(to: .review) }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.pendingPlan == nil || viewModel.isBusy || viewModel.isSelectionLocked)
            }
            .padding(12)
        }
    }
}
