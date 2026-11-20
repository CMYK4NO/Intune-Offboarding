import OffboardingCore
import SwiftUI

/// Everything that would happen, before anything is run. Destructive actions are colour-coded.
struct ReviewView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel
    let plan: OffboardingPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("OFFBOARDING REVIEW").font(.title2).fontWeight(.bold)
                UserSummaryView(user: plan.user)

                Label(summaryText, systemImage: viewModel.mode == .simulation ? "testtube.2" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.mode == .simulation ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)

                if let violation = plan.safetyViolation {
                    Label(violation, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !plan.deviceActions.isEmpty {
                    section("MDM", plan.deviceActions)
                }
                if !plan.mamActions.isEmpty {
                    mamSection
                }

                if !viewModel.validationIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Validation failed. Nothing was run.", systemImage: "xmark.octagon.fill")
                            .fontWeight(.semibold)
                        ForEach(Array(viewModel.validationIssues.enumerated()), id: \.offset) { _, issue in
                            Text("• \(issue.localizedDescription)")
                        }
                        Text("Go back, let discovery reload and review again.")
                            .font(.footnote)
                    }
                    .foregroundStyle(.red)
                }

                confirmation

                HStack {
                    Button("Back") { viewModel.backToSelection() }
                        .disabled(viewModel.isBusy)
                    Button(viewModel.mode == .simulation ? "Validate and run simulation" : "Validate and execute") {
                        viewModel.run()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.mode == .simulation ? .orange : .red)
                    .disabled(!viewModel.canRun)
                    if viewModel.isBusy { ProgressView().controlSize(.small) }
                }

                if viewModel.isConfirmingIdentity {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Confirm it is you: sign in again in the browser window that just opened.",
                              systemImage: "person.badge.key.fill")
                            .fontWeight(.semibold)
                        Text("Use the same administrator account. Nothing has been sent yet; if a different account signs in, "
                             + "the run is refused.")
                            .font(.footnote)
                        Button("Cancel") { viewModel.cancelIdentityConfirmation() }
                    }
                    .foregroundStyle(.blue)
                } else if viewModel.mode == .production && !viewModel.isBusy {
                    Text("Before anything is sent you will be asked to sign in again in your browser.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Final confirmation; wipes also need a typed phrase, and wipes and record deletes get a second confirmation after pressing Run.
    @ViewBuilder private var confirmation: some View {
        if let policy = viewModel.policy {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(([policy.warning, ""] + policy.destructiveDeviceLines).joined(separator: "\n")).fontWeight(.semibold)
                        .foregroundStyle(policy.requiresSecondConfirmation ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I have reviewed the actions above for \(plan.user.userPrincipalName)",
                           isOn: $viewModel.acknowledged)
                    if let phrase = policy.requiredPhrase {
                        HStack {
                            Text("Type").foregroundStyle(.secondary)
                            Text(phrase).font(.body.monospaced()).fontWeight(.bold)
                            Text("to enable wipe:").foregroundStyle(.secondary)
                            TextField("", text: $viewModel.typedPhrase)
                                .textFieldStyle(.roundedBorder).frame(width: 140)
                                .autocorrectionDisabled()
                        }
                    }
                }
                .disabled(viewModel.isBusy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .alert(policy.alertTitle, isPresented: secondConfirmationShown) {
                Button("Cancel", role: .cancel) {}
                Button(policy.alertButtonTitle, role: .destructive) { viewModel.confirmSecond() }
            } message: {
                Text(([policy.warning, ""] + policy.destructiveDeviceLines).joined(separator: "\n"))
            }
        }
    }

    /// The alert closes itself by writing `false` during a view update. Deferring that write avoids publishing
    /// from inside the update; the Cancel and confirm buttons run their own actions as before.
    private var secondConfirmationShown: Binding<Bool> {
        Binding(get: { viewModel.showSecondConfirmation }, set: { shown in
            guard shown != viewModel.showSecondConfirmation else { return }
            DispatchQueue.main.async { viewModel.showSecondConfirmation = shown }
        })
    }

    private var summaryText: String {
        var parts: [String] = []
        if plan.wipeCount > 0 { parts.append("wipe \(plan.wipeCount) device(s)") }
        if plan.retireCount > 0 { parts.append("retire \(plan.retireCount) device(s)") }
        if plan.deleteCount > 0 { parts.append("delete \(plan.deleteCount) Intune record(s)") }
        if plan.selectiveWipeCount > 0 { parts.append("selectively wipe app data on \(plan.selectiveWipeDeviceCount) device(s)") }
        let list = parts.joined(separator: ", ")
        return viewModel.mode == .simulation
            ? "Simulation: this would \(list). No changes will be made."
            : "You are about to \(list). This cannot be undone."
    }

    /// One box per phone, listing every app group (device tag) that gets its own selective-wipe request.
    private var mamSection: some View {
        var order: [String] = []
        var byHost: [String: [PlannedAction]] = [:]
        for planned in plan.mamActions {
            let key = planned.hostID ?? planned.asset.rawID
            if byHost[key] == nil { order.append(key) }
            byHost[key, default: []].append(planned)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("MAM").font(.headline).foregroundStyle(.secondary)
            ForEach(order, id: \.self) { key in
                MAMHostReviewRow(actions: byHost[key] ?? [])
            }
        }
    }

    private func section(_ title: String, _ actions: [PlannedAction]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            ForEach(actions) { PlannedActionRow(planned: $0) }
        }
    }
}

struct PlannedActionRow: View {
    let planned: PlannedAction

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(planned.label).fontWeight(.semibold)
                    Spacer()
                    Text(planned.action.title.uppercased())
                        .font(.caption).fontWeight(.bold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(planned.action.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(planned.action.tint)
                }
                Text([planned.ownership, planned.serialNumber.map { "Serial \($0)" }]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(planned.action.explanation).font(.caption).foregroundStyle(.secondary)
                if !planned.wipeOptions.isFullWipe {
                    Label(planned.wipeOptions.summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).fontWeight(.bold).foregroundStyle(.orange)
                }
                Text(planned.apiOperation).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A phone in Review: its selective wipe, then the exact requests (one per device tag) that will be sent.
struct MAMHostReviewRow: View {
    let actions: [PlannedAction]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(actions.first?.hostLabel ?? actions.first?.label ?? "Device").fontWeight(.semibold)
                    Spacer()
                    Text(OffboardingAction.mamSelectiveWipe.title.uppercased())
                        .font(.caption).fontWeight(.bold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(OffboardingAction.mamSelectiveWipe.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(OffboardingAction.mamSelectiveWipe.tint)
                }
                Text(OffboardingAction.mamSelectiveWipe.explanation).font(.caption).foregroundStyle(.secondary)
                Text(actions.count == 1 ? "1 request to Intune:" : "\(actions.count) requests to Intune, one per app group:")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(actions) { planned in
                    Text("• \(planned.label)").font(.caption)
                    Text(planned.apiOperation).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
