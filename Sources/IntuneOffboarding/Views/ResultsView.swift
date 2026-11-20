import AppKit
import OffboardingCore
import SwiftUI

/// Live progress and final outcome. In simulation it states plainly that nothing was changed.
struct ResultsView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel
    let result: OffboardingResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2).fontWeight(.bold)
                if result.mode == .simulation {
                    Label("SIMULATION — No changes were made.", systemImage: "testtube.2")
                        .fontWeight(.semibold).foregroundStyle(.orange)
                }

                if result.operations.isEmpty {
                    ProgressView("Starting…")
                }
                ForEach(result.operations) { operation in
                    GroupBox {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(operation.state)).foregroundStyle(color(operation.state))
                                .accessibilityLabel(label(operation.state))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(operation.assetLabel).fontWeight(.semibold)
                                Text(operation.action.title).foregroundStyle(operation.action.tint)
                                if let api = operation.apiOperation {
                                    Text(api).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Text(operation.message.isEmpty ? label(operation.state) : operation.message)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let registration = operation.intuneRegistration {
                                    Label(registrationText(registration), systemImage: registrationIcon(registration))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(registrationColor(registration))
                                }
                                if let pin = operation.macOsUnlockCode {
                                    Label("Mac unlock PIN: \(pin)", systemImage: "key.fill")
                                        .font(.callout.monospacedDigit().weight(.semibold))
                                        .textSelection(.enabled)
                                        .help("Needed only if the Mac asks for it after the erase (older Macs without a T2 chip). Not saved anywhere by this app.")
                                }
                            }
                            Spacer()
                        }
                    }
                }

                HStack {
                    Button("Back to selection") { viewModel.backToSelection() }
                        .disabled(viewModel.isBusy)
                    Button("Start over with another user") { viewModel.startOver() }
                        .disabled(viewModel.isBusy)
                    if let folder = viewModel.auditDirectory {
                        Button("Show audit log") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        switch result.summary {
        case .simulated: return "Simulation complete"
        case .completed: return "Offboarding completed"
        case .completedWithWarnings: return "Offboarding completed with warnings"
        case .failed: return "Offboarding failed"
        case .inProgress: return result.mode == .simulation ? "Running simulation…" : "Running…"
        case .nothingToDo: return "Nothing to do"
        case .notExecuted: return "Nothing was executed"
        }
    }

    private func registrationText(_ registration: IntuneRegistration) -> String {
        switch registration {
        case .registered: return "Intune registered the action"
        case .failedInIntune: return "Intune already marked it failed"
        case .notRegistered: return "Intune shows no new action: check the device in Intune"
        case .recordRemoved: return "Record already removed: action most likely completed"
        case .unverified: return "Could not confirm in Intune"
        }
    }

    private func registrationIcon(_ registration: IntuneRegistration) -> String {
        switch registration {
        case .registered: return "checkmark.seal.fill"
        case .failedInIntune: return "xmark.octagon.fill"
        case .notRegistered: return "exclamationmark.triangle.fill"
        case .recordRemoved: return "checkmark.seal"
        case .unverified: return "questionmark.circle"
        }
    }

    private func registrationColor(_ registration: IntuneRegistration) -> Color {
        switch registration {
        case .registered: return .green
        case .failedInIntune: return .red
        case .notRegistered: return .orange
        case .recordRemoved: return .green
        case .unverified: return .secondary
        }
    }

    private func icon(_ state: OperationState) -> String {
        switch state {
        case .pending: return "clock"
        case .validating, .executing: return "arrow.triangle.2.circlepath"
        case .submitted, .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .outcomeUnknown: return "questionmark.circle.fill"
        case .skipped: return "eye.circle.fill"
        }
    }

    private func color(_ state: OperationState) -> Color {
        switch state {
        case .submitted, .succeeded: return .green
        case .failed: return .red
        case .outcomeUnknown: return .orange
        case .skipped: return .blue
        default: return .gray
        }
    }

    private func label(_ state: OperationState) -> String {
        switch state {
        case .pending: return "Pending"
        case .validating: return "Validating…"
        case .executing: return "Running…"
        case .submitted: return "Request submitted"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .outcomeUnknown: return "Outcome unknown, verify before retrying"
        case .skipped: return "Not executed"
        }
    }
}
