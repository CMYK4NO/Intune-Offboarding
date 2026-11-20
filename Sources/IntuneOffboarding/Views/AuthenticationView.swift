import OffboardingCore
import SwiftUI

struct AuthenticationView: View {
    @EnvironmentObject private var auth: AuthenticationService
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Sign in with your administrator account")
                .font(.title3)
            if !settings.isConfigured {
                Text("First enter your Microsoft Entra app registration IDs in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button {
                Task { await auth.signIn() }
            } label: {
                if case .signingIn = auth.state {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign in with Microsoft")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || !settings.isConfigured)

            Button("Settings…") { showSettings = true }
                .disabled(isSigningIn)

            if isSigningIn {
                Text("Finish signing in in your browser, then return here.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { auth.cancelSignIn() }
            }

            if case .failed(let message) = auth.state {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if !settings.isConfigured { showSettings = true } }
        .sheet(isPresented: $showSettings) {
            SettingsView(onDone: { showSettings = false })
                .environmentObject(settings)
                .environmentObject(auth)
        }
    }

    private var isSigningIn: Bool {
        if case .signingIn = auth.state { return true }
        return false
    }
}

