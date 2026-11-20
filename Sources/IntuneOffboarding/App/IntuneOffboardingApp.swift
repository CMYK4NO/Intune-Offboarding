import AppKit
import OffboardingCore
import SwiftUI

/// True while a run is validating or executing. Read by the quit guard, so it is lock-protected.
enum RunGuard {
    private static let lock = NSLock()
    private static var active = false
    static var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    static func set(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
}

/// Shows the launch splash, and refuses to quit while a run is in progress: quitting between sending a wipe or delete and writing its
/// audit record would leave an action with no record of its outcome.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SplashController.shared.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RunGuard.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An offboarding run is in progress"
        alert.informativeText = "Quitting now could leave a request sent but not recorded. Wait for the run to finish, then quit."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct IntuneOffboardingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var auth: AuthenticationService
    @StateObject private var viewModel: OffboardingViewModel

    init() {
        Self.loadDockIcon()
        // Composition root: auth → GraphClient → services → view model.
        let settings = AppSettings()
        let auth = AuthenticationService(settings: settings)
        let graph = GraphClient(tokenProvider: auth, scopes: AuthConfiguration.discoveryScopes)
        // Separate client for writes: only the production executor ever receives it.
        let writeGraph = GraphClient(tokenProvider: auth, scopes: AuthConfiguration.signInScopes)
        // Read-only beta client: only for app-protection device details missing from v1.0 (Entra device ID, model).
        let betaGraph = GraphClient(tokenProvider: auth, scopes: AuthConfiguration.discoveryScopes, baseURL: GraphClient.betaBase)
        let audit = AuditService(directory: AuditService.defaultDirectory())
        _settings = StateObject(wrappedValue: settings)
        _auth = StateObject(wrappedValue: auth)
        _viewModel = StateObject(wrappedValue: OffboardingViewModel(
            userService: UserService(graph: graph),
            deviceService: IntuneDeviceService(graph: graph),
            mamService: MAMService(graph: graph, details: BetaMAMDeviceDetailsService(graph: betaGraph)),
            productionExecutor: ProductionExecutor(
                actions: IntuneDeviceActionService(graph: writeGraph),
                mam: MAMActionService(graph: writeGraph, discovery: MAMService(graph: graph)),
                auth: auth,
                scopes: AuthConfiguration.signInScopes,
                verificationDelay: 10),
            audit: audit,
            reauthenticator: auth,
            adminProvider: { [weak auth] in
                if case .signedIn(let session)? = auth?.state { return session }
                return nil
            }))
    }

    /// Sets the Dock icon from the bundled AppIcon.icns, so it shows even when Launch Services has a stale icon cached.
    private static func loadDockIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }

    var body: some Scene {
        WindowGroup("Device Offboarding") {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(auth)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 520)
                .background(SplashGate())
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(auth)
        }
    }
}
