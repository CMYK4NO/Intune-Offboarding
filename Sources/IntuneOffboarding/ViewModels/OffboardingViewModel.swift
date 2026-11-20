import Foundation
import OffboardingCore

/// The workflow: Authenticate → Search → Discover/Select actions → Review → Execute → Results.
enum WorkflowStep: Int, CaseIterable, Identifiable {
    case authenticate, search, discover, selectActions, review, execute, results

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .authenticate: return "Authenticate"
        case .search: return "Search by UPN"
        case .discover: return "Discover assets"
        case .selectActions: return "Select actions"
        case .review: return "Review"
        case .execute: return "Execute"
        case .results: return "Results"
        }
    }
}

/// Pages of the sidebar. The workflow order is fixed: nothing after `user` is reachable until a user is confirmed.
enum SidebarPage: String, CaseIterable, Identifiable {
    case user, devices, appProtection, review, results, auditLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: return "User"
        case .devices: return "Devices"
        case .appProtection: return "App protection"
        case .review: return "Review"
        case .results: return "Results"
        case .auditLog: return "Audit log"
        }
    }

    var systemImage: String {
        switch self {
        case .user: return "person.crop.circle"
        case .devices: return "laptopcomputer"
        case .appProtection: return "lock.shield"
        case .review: return "checklist"
        case .results: return "flag.checkered"
        case .auditLog: return "doc.text.magnifyingglass"
        }
    }
}

enum LookupState: Equatable {
    case idle
    case searching
    case resolved(EntraUser)
    case failed(String)
}

/// Loading state of one discovery. MDM and MAM each have their own, so a failure in one
/// never hides the other's results.
enum DiscoveryState<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

@MainActor
final class OffboardingViewModel: ObservableObject {
    /// Always starts in simulation; production must be enabled explicitly (Phase 7+).
    @Published private(set) var mode: ExecutionMode = .simulation
    @Published private(set) var step: WorkflowStep = .search
    /// Page shown in the sidebar. Changed by the workflow itself and by `navigate(to:)`.
    @Published private(set) var page: SidebarPage = .user

    @Published var upnInput = ""
    @Published private(set) var lookup: LookupState = .idle
    /// Set only after the admin explicitly confirms the resolved identity.
    @Published private(set) var confirmedUser: EntraUser?

    @Published private(set) var deviceDiscovery: DiscoveryState<DeviceDiscoveryResult> = .idle
    @Published private(set) var mamDiscovery: DiscoveryState<MAMDiscoveryResult> = .idle

    @Published private(set) var selection = OffboardingSelection()
    @Published private(set) var plan: OffboardingPlan?
    @Published private(set) var validationIssues: [PlanValidationIssue] = []
    /// True while validating or executing: all action controls are disabled and a second run is refused.
    @Published private(set) var isBusy = false { didSet { RunGuard.set(isBusy) } }
    @Published private(set) var result: OffboardingResult?

    /// Final confirmation and, for wipes, the typed phrase. Reset whenever a review starts.
    @Published var acknowledged = false
    @Published var typedPhrase = ""
    /// Second confirmation for wipes and record deletes: the review screen shows an alert listing the devices.
    @Published var showSecondConfirmation = false
    /// True while a production run waits for the administrator to sign in again in the browser.
    @Published private(set) var isConfirmingIdentity = false

    private let userService: UserResolving
    private let deviceService: DeviceDiscovering
    private let mamService: MAMDiscovering
    private let validator: PlanValidator
    private let simulationExecutor: OffboardingExecuting
    private let productionExecutor: OffboardingExecuting?
    private let audit: AuditRecording?
    /// Fresh sign-in required before every production run. A production run without it is refused.
    private let reauthenticator: Reauthenticating?
    /// Current administrator (for the audit trail); evaluated when a run starts.
    private let adminProvider: @MainActor () -> AdminSession?
    private var searchTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var mamTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    init(
        userService: UserResolving, deviceService: DeviceDiscovering, mamService: MAMDiscovering,
        simulationExecutor: OffboardingExecuting = SimulationExecutor(),
        productionExecutor: OffboardingExecuting? = nil,
        audit: AuditRecording? = nil,
        reauthenticator: Reauthenticating? = nil,
        adminProvider: @escaping @MainActor () -> AdminSession? = { nil }
    ) {
        self.userService = userService
        self.deviceService = deviceService
        self.mamService = mamService
        self.simulationExecutor = simulationExecutor
        self.productionExecutor = productionExecutor
        self.audit = audit
        self.reauthenticator = reauthenticator
        self.adminProvider = adminProvider
        self.validator = PlanValidator(users: userService, devices: deviceService, mam: mamService)
    }

    // MARK: - Search

    func search() {
        searchTask?.cancel()
        confirmedUser = nil
        lookup = .searching
        let upn = upnInput
        searchTask = Task {
            do {
                let user = try await userService.resolve(upn: upn)
                if !Task.isCancelled { lookup = .resolved(user) }
            } catch is CancellationError {
                // superseded by a newer search or edit
            } catch {
                if !Task.isCancelled { lookup = .failed(error.localizedDescription) }
            }
        }
    }

    /// Any edit invalidates a previous result, so the confirmed identity always matches the text on screen.
    func upnEdited() {
        searchTask?.cancel()
        clearWorkflow()
        confirmedUser = nil
        lookup = .idle
        step = .search
        page = .user
    }

    func confirmUser() {
        guard case .resolved(let user) = lookup else { return }
        confirmedUser = user
        step = .selectActions
        page = .devices
        startDeviceDiscovery(for: user)
        startMAMDiscovery(for: user)
    }

    func retryDeviceDiscovery() {
        guard let user = confirmedUser else { return }
        startDeviceDiscovery(for: user)
    }

    func retryMAMDiscovery() {
        guard let user = confirmedUser else { return }
        startMAMDiscovery(for: user)
    }


    func changeUser() { upnEdited() }

    // MARK: - Sidebar navigation

    /// Which pages can be opened now. Pages only show state; they never start anything destructive.
    func isAvailable(_ page: SidebarPage) -> Bool {
        switch page {
        case .user, .auditLog: return true
        case .devices, .appProtection: return confirmedUser != nil
        // The Review page is a live view of the current selection: open from the moment a user is confirmed.
        case .review: return confirmedUser != nil && step == .selectActions
        case .results: return result != nil
        }
    }

    /// The sidebar is frozen while a run is validating or executing, so nobody can wander off mid-run.
    func navigate(to newPage: SidebarPage) {
        guard !isBusy, isAvailable(newPage) else { return }
        page = newPage
    }

    /// Called on sign-out: drop everything tied to the previous administrator session.
    func reset() {
        upnInput = ""
        upnEdited()
    }

    // MARK: - Mode

    var canUseProduction: Bool { productionExecutor != nil }

    /// Mode can only change while choosing actions, never during review or a run. It always falls
    /// back to simulation when the user changes or the admin signs out.
    func setMode(_ newMode: ExecutionMode) {
        guard !isBusy, step == .selectActions else { return }
        if newMode == .production && productionExecutor == nil { return }
        mode = newMode
        syncPlan()
    }

    // MARK: - Action selection and review

    /// Selection is locked while a run is in progress.
    var isSelectionLocked: Bool { isBusy || step != .selectActions }

    func action(for asset: AssetID) -> OffboardingAction { selection.action(for: asset) }

    func setAction(_ action: OffboardingAction, for asset: AssetID) {
        guard !isSelectionLocked else { return }
        selection.set(action, for: asset)
        syncPlan()
    }

    /// A phone's action is the action of its device-tag groups; the phone row is the only place they are set,
    /// so they always match. Groups without a tag cannot be wiped and keep No Action.
    func action(for host: MAMHostDevice) -> OffboardingAction {
        host.wipeableGroups.first.map { selection.action(for: .mamDeviceGroup($0.id)) } ?? .noAction
    }

    /// True if the phone's groups disagree, which only happens when a reload regroups the phones after a choice
    /// (for example a new app registered). Review lists exactly which groups are included either way.
    func hasMixedActions(_ host: MAMHostDevice) -> Bool {
        Set(host.wipeableGroups.map { selection.action(for: .mamDeviceGroup($0.id)) }).count > 1
    }

    func setAction(_ action: OffboardingAction, for host: MAMHostDevice) {
        guard !isSelectionLocked else { return }
        for group in host.wipeableGroups { selection.set(action, for: .mamDeviceGroup(group.id)) }
        syncPlan()
    }

    /// Windows wipe switches of one device (all off = full wipe). Only effective while its action is Wipe Device.
    func wipeOptions(for asset: AssetID) -> WipeOptions { selection.wipeOptions(for: asset) }

    func setWipeOptions(_ options: WipeOptions, for asset: AssetID) {
        guard !isSelectionLocked else { return }
        selection.setWipeOptions(options, for: asset)
        syncPlan()
    }

    /// Keeps the Review page in step with the selection. Any change also clears the acknowledgement and the
    /// typed phrase, so a confirmation always refers to exactly the plan on screen. Frozen once a run starts.
    private func syncPlan() {
        guard step == .selectActions, !isBusy else { return }
        plan = pendingPlan
        resetConfirmation()
        validationIssues = []
    }

    /// Plan for the current selection (destructive choices only).
    var pendingPlan: OffboardingPlan? {
        guard let user = confirmedUser else { return nil }
        var devices: [ManagedDevice] = []
        var groups: [MAMDeviceGroup] = []
        if case .loaded(let found) = deviceDiscovery { devices = found.devices }
        if case .loaded(let found) = mamDiscovery { groups = found.groups }
        let plan = selection.makePlan(
            user: user, mode: mode, devices: devices, mamGroups: groups)
        return plan.actions.isEmpty ? nil : plan
    }

    func backToSelection() {
        guard !isBusy else { return }
        // After a production run its choices are spent. Start again from No Action, in simulation and with fresh
        // lists, so nothing that was already wiped or deleted can be sent a second time by accident.
        if result?.mode == .production, let user = confirmedUser {
            selection.clear()
            mode = .simulation
            startDeviceDiscovery(for: user)
            startMAMDiscovery(for: user)
        }
        result = nil
        step = .selectActions
        page = .devices
        syncPlan()
    }

    // MARK: - Confirmation and run (simulation only in this phase)

    var policy: ConfirmationPolicy? { plan.map(ConfirmationPolicy.init) }

    /// The Run button is enabled only when the policy is satisfied and nothing is running.
    var canRun: Bool {
        guard !isBusy, step == .selectActions, let policy else { return false }
        return policy.isSatisfied(acknowledged: acknowledged, typedPhrase: typedPhrase)
    }

    /// Entry point of the Run button. Checks the policy again, then either asks the second confirmation
    /// (plans with a wipe or a record delete) or starts at once. Starting locks the UI immediately (double-submit guard).
    func run() {
        guard canRun, let plan, plan == pendingPlan else { return }
        if ConfirmationPolicy(plan: plan).requiresSecondConfirmation {
            showSecondConfirmation = true
            return
        }
        start(plan)
    }

    /// Second confirmation answered in the review alert.
    func confirmSecond() {
        guard canRun, let plan, plan == pendingPlan else { return }
        start(plan)
    }

    private func start(_ plan: OffboardingPlan) {
        isBusy = true
        validationIssues = []
        runTask = Task { await validateAndExecute(plan) }
    }

    private func resetConfirmation() {
        acknowledged = false
        typedPhrase = ""
        showSecondConfirmation = false
    }

    /// Re-validates identity and assets (read-only), then runs the executor. Any difference from what
    /// was reviewed blocks the run.
    private func validateAndExecute(_ plan: OffboardingPlan) async {
        let executor: OffboardingExecuting? = plan.mode == .production ? productionExecutor : simulationExecutor
        guard let executor else {
            isBusy = false
            return
        }
        // Production: the administrator proves it is really them, now, before anything is validated or sent.
        if plan.mode == .production {
            guard await confirmIdentity() else { return }
        }
        let issues = await validator.validate(plan)
        guard !Task.isCancelled else { return } // reset (sign-out, user change) while validating
        guard issues.isEmpty else {
            validationIssues = issues
            isBusy = false
            return
        }
        let admin = adminProvider()
        var runId: String?
        if let audit, let admin { runId = await audit.recordRunStarted(plan: plan, admin: admin) }
        // A reset (sign-out, user change) during the audit write ends the run here: nothing was sent yet.
        guard !Task.isCancelled else { return }
        // Fail closed: a production run needs a written audit record BEFORE anything is sent.
        if plan.mode == .production && runId == nil {
            validationIssues = [.auditUnavailable]
            isBusy = false
            return
        }
        result = OffboardingResult(mode: plan.mode, operations: [])
        step = .execute
        page = .results
        let final = await executor.execute(plan) { [weak self] update in
            await self?.apply(update)
        }
        // Recorded even if the workflow was reset meanwhile: whatever was sent really happened.
        if let audit, let admin, let runId { await audit.recordRun(runId: runId, plan: plan, result: final, admin: admin) }
        guard !Task.isCancelled else { return } // reset happened mid-run: do not resurrect the old workflow
        result = final
        step = .results
        isBusy = false
    }

    /// Runs the fresh sign-in. Returns true only when the same administrator confirmed; otherwise the reason is
    /// shown and the run ends with nothing sent.
    private func confirmIdentity() async -> Bool {
        guard let reauthenticator, let current = adminProvider() else {
            validationIssues = [.reauthenticationFailed("No identity check is available in this build.")]
            isBusy = false
            return false
        }
        isConfirmingIdentity = true
        defer { isConfirmingIdentity = false }
        do {
            let confirmed = try await reauthenticator.reauthenticate()
            guard !Task.isCancelled else { return false } // reset (sign-out, user change) meanwhile
            guard confirmed.isSameAccount(as: current) else {
                validationIssues = [.reauthenticationFailed("The signed-in account changed.")]
                isBusy = false
                return false
            }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            validationIssues = [.reauthenticationFailed(error.localizedDescription)]
            isBusy = false
            return false
        }
    }

    /// Abandons the confirmation sign-in; the run then ends with nothing sent.
    func cancelIdentityConfirmation() {
        guard isConfirmingIdentity, let reauthenticator else { return }
        Task { await reauthenticator.cancelReauthentication() }
    }

    /// Folder of the local audit trail, when auditing is configured.
    var auditDirectory: URL? { audit?.directory }

    func loadAuditRecords() async -> [AuditRecord] {
        await audit?.recentRecords(limit: 500) ?? []
    }

    func startOver() {
        guard !isBusy else { return }
        upnInput = ""
        upnEdited()
    }

    private func apply(_ update: OperationResult) {
        guard !Task.isCancelled else { return }
        var current = result ?? OffboardingResult(mode: mode, operations: [])
        if let index = current.operations.firstIndex(where: { $0.id == update.id }) {
            current.operations[index] = update
        } else {
            current.operations.append(update)
        }
        result = current
    }

    // MARK: - Read-only discovery (nothing here can change tenant state)

    private func startDeviceDiscovery(for user: EntraUser) {
        deviceTask?.cancel()
        deviceDiscovery = .loading
        deviceTask = Task {
            do {
                let found = try await deviceService.discoverDevices(for: user)
                if !Task.isCancelled {
                    deviceDiscovery = .loaded(found)
                    syncPlan()
                }
            } catch is CancellationError {
                // superseded
            } catch {
                if !Task.isCancelled { deviceDiscovery = .failed(error.localizedDescription) }
            }
        }
    }


    private func startMAMDiscovery(for user: EntraUser) {
        mamTask?.cancel()
        mamDiscovery = .loading
        mamTask = Task {
            do {
                let found = try await mamService.discoverRegistrations(for: user)
                if !Task.isCancelled { mamDiscovery = .loaded(found); syncPlan() }
            } catch is CancellationError {
                // superseded
            } catch {
                if !Task.isCancelled { mamDiscovery = .failed(error.localizedDescription) }
            }
        }
    }

    /// Drops discovery, selection, plan and results (user changed, edited UPN or signed out).
    private func clearWorkflow() {
        deviceTask?.cancel()
        mamTask?.cancel()
        runTask?.cancel()
        deviceDiscovery = .idle
        mamDiscovery = .idle
        selection.clear()
        mode = .simulation
        plan = nil
        resetConfirmation()
        result = nil
        validationIssues = []
        isBusy = false
    }
}
