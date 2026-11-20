import AppKit
import OffboardingCore
import SwiftUI

/// The Microsoft Entra app registration the app signs in with. Shown as a sheet on the sign-in screen (opened
/// automatically on first launch) and as the app's Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var auth: AuthenticationService

    /// Set when shown as a sheet: closes it. Nil in the Settings window.
    var onDone: (() -> Void)?

    @State private var clientId = ""
    @State private var tenantId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section {
                    field("Application (client) ID", text: $clientId)
                    field("Directory (tenant) ID", text: $tenantId)
                } header: {
                    Text("Microsoft Entra app registration")
                } footer: {
                    Text("Both are GUIDs from the app registration's Overview page. They are identifiers, not secrets: this is a public client and never uses a client secret. Register `http://localhost` as a Mobile and desktop redirect URI (see docs/EntraAppRegistration.md).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(locked)

            if settings.isManaged {
                Label("These values are set by your organisation and cannot be changed here.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if sessionOpen {
                Label("Sign out to change these values.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if let onDone {
                    Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                }
                Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(locked || AuthConfiguration(clientId: clientId, tenantId: tenantId) == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            clientId = settings.clientId
            tenantId = settings.tenantId
        }
    }

    /// Stores the values, then closes whichever window this is shown in: the sheet via `onDone`, or the Settings window.
    private func save() {
        guard settings.save(clientId: clientId, tenantId: tenantId) else { return }
        if let onDone { onDone() } else { NSApp.keyWindow?.close() }
    }

    /// Text field with a red hint when a value was typed but is not a GUID.
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: text, prompt: Text("00000000-0000-0000-0000-000000000000"))
                .autocorrectionDisabled()
            if !text.wrappedValue.isEmpty, AuthConfiguration.normalizedGUID(text.wrappedValue) == nil {
                Text("Not a valid GUID.").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var sessionOpen: Bool {
        switch auth.state {
        case .signedOut, .failed: return false
        case .signingIn, .signedIn: return true
        }
    }

    private var locked: Bool { settings.isManaged || sessionOpen }
}
