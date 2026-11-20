import OffboardingCore
import SwiftUI

/// UPN search. Contains no destructive controls.
struct SearchView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find user").font(.title2).fontWeight(.semibold)
            HStack {
                TextField("user@company.com", text: $viewModel.upnInput)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { viewModel.search() }
                    .onChange(of: viewModel.upnInput) { _ in viewModel.upnEdited() }
                Button("Search") { viewModel.search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSearching || viewModel.upnInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Exact UPN only. No partial or fuzzy matching.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            switch viewModel.lookup {
            case .idle:
                EmptyView()
            case .searching:
                ProgressView("Resolving user…")
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .resolved(let user):
                UserSummaryView(user: user) { viewModel.confirmUser() }
            }
            Spacer()
        }
        .padding(24)
    }

    private var isSearching: Bool { viewModel.lookup == .searching }
}
