import XCTest
@testable import OffboardingCore

// MARK: - Helpers

private let testUser = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

private func device(_ id: String, serial: String = "SN1", userId: String = "u1", os: String = "Windows") -> ManagedDevice {
    try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(
        #"{"id":"\#(id)","deviceName":"PC \#(id)","serialNumber":"\#(serial)","userId":"\#(userId)","operatingSystem":"\#(os)","managedDeviceOwnerType":"company"}"#.utf8))
}

private func graph(_ transport: MockTransport) -> GraphClient {
    GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport)
}

// MARK: - Wipe options (Windows)

final class WipeOptionsTests: XCTestCase {
    private func body(_ options: WipeOptions) throws -> [String: Bool]? {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(WipeRequestBody(options))) as? [String: Bool]
    }

    func testDefaultBodyIsAFullWipeWithEveryKeyExplicit() throws {
        XCTAssertEqual(try body(.fullWipe), ["keepEnrollmentData": false, "keepUserData": false, "persistEsimDataPlan": false])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(WipeRequestBody())) as? [String: Bool],
                       ["keepEnrollmentData": false, "keepUserData": false, "persistEsimDataPlan": false])
    }

    func testKeepSwitchesAreSentOnlyWhenChosen() throws {
        XCTAssertEqual(try body(WipeOptions(keepEnrollmentData: true)),
                       ["keepEnrollmentData": true, "keepUserData": false, "persistEsimDataPlan": false])
        XCTAssertEqual(try body(WipeOptions(keepUserData: true)),
                       ["keepEnrollmentData": false, "keepUserData": true, "persistEsimDataPlan": false])
    }

    func testSummaryNamesWhatIsKept() {
        XCTAssertTrue(WipeOptions.fullWipe.isFullWipe)
        XCTAssertEqual(WipeOptions.fullWipe.summary, "")
        XCTAssertEqual(WipeOptions(keepEnrollmentData: true, keepUserData: true).summary, "KEEPS enrollment data, KEEPS user data")
        XCTAssertFalse(WipeOptions(keepUserData: true).isFullWipe)
    }

    func testServiceSendsTheOptionsInTheRealRequest() async throws {
        let t = MockTransport([.success(.init(status: 204, body: ""))])
        let status = try await IntuneDeviceActionService(graph: graph(t)).wipe(deviceID: "d1", options: WipeOptions(keepUserData: true))
        XCTAssertEqual(status, 204)
        XCTAssertEqual(t.requests.count, 1)
        let sent = try JSONSerialization.jsonObject(with: t.requests[0].httpBody ?? Data()) as? [String: Bool]
        XCTAssertEqual(sent, ["keepEnrollmentData": false, "keepUserData": true, "persistEsimDataPlan": false])
    }

    func testOnlyWindowsDevicesAreWindows() {
        XCTAssertTrue(device("d1", os: "Windows").isWindows)
        XCTAssertFalse(device("d2", os: "macOS").isWindows)
        XCTAssertFalse(device("d3", os: "iOS").isWindows)
    }
}

// MARK: - Selection and plan

final class WindowsSelectionTests: XCTestCase {
    func testOptionsApplyOnlyWhileWipeIsChosenAndResetWhenLeavingIt() {
        var selection = OffboardingSelection()
        let asset = AssetID.managedDevice("d1")
        selection.setWipeOptions(WipeOptions(keepUserData: true), for: asset) // no wipe chosen yet: ignored
        XCTAssertTrue(selection.wipeOptions(for: asset).isFullWipe)

        selection.set(.mdmWipe, for: asset)
        selection.setWipeOptions(WipeOptions(keepUserData: true), for: asset)
        XCTAssertTrue(selection.wipeOptions(for: asset).keepUserData)

        selection.set(.deleteIntuneRecord, for: asset)
        XCTAssertTrue(selection.wipeOptions(for: asset).isFullWipe)
        selection.set(.mdmWipe, for: asset) // choosing Wipe again starts from a full wipe
        XCTAssertTrue(selection.wipeOptions(for: asset).isFullWipe)
    }

    func testWindowsWipeCarriesItsOptionsIntoThePlanAndTheApiText() {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        let full = selection.makePlan(user: testUser, mode: .production, devices: [device("d1")], mamGroups: [])
        selection.setWipeOptions(WipeOptions(keepEnrollmentData: true), for: .managedDevice("d1"))
        let keeping = selection.makePlan(user: testUser, mode: .production, devices: [device("d1")], mamGroups: [])

        XCTAssertTrue(full.actions[0].wipeOptions.isFullWipe)
        XCTAssertFalse(full.actions[0].apiOperation.contains("KEEPS"))
        XCTAssertTrue(keeping.actions[0].wipeOptions.keepEnrollmentData)
        XCTAssertTrue(keeping.actions[0].apiOperation.contains("KEEPS enrollment data"))
        XCTAssertNotEqual(full, keeping) // a changed switch is a changed plan: the confirmation must be given again
    }

    func testNonWindowsDeviceIsAlwaysAFullWipe() {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("m1"))
        selection.setWipeOptions(WipeOptions(keepEnrollmentData: true, keepUserData: true), for: .managedDevice("m1"))
        let plan = selection.makePlan(user: testUser, mode: .production, devices: [device("m1", os: "macOS")], mamGroups: [])
        XCTAssertTrue(plan.actions[0].wipeOptions.isFullWipe)
        XCTAssertFalse(plan.actions[0].apiOperation.contains("KEEPS"))
    }
}

// MARK: - Confirmation wording

final class WindowsConfirmationTests: XCTestCase {
    private func plan(keep: WipeOptions = .fullWipe) -> OffboardingPlan {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        selection.setWipeOptions(keep, for: .managedDevice("d1"))
        return selection.makePlan(user: testUser, mode: .production, devices: [device("d1")], mamGroups: [])
    }

    func testAWipeThatKeepsDataSaysSoWhereTheAdministratorConfirms() {
        let policy = ConfirmationPolicy(plan: plan(keep: WipeOptions(keepUserData: true)))
        XCTAssertTrue(policy.warning.contains("keep data"))
        XCTAssertTrue(policy.destructiveDeviceLines[0].contains("KEEPS user data"))
        let full = ConfirmationPolicy(plan: plan())
        XCTAssertFalse(full.warning.contains("keep data"))
        XCTAssertFalse(full.destructiveDeviceLines[0].contains("KEEPS"))
    }
}

// MARK: - Executor

private final class DeviceFake: DeviceActionPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var wipedWith: [String: WipeOptions] = [:]
    var devices: [String: ManagedDevice] = [:]

    var wiped: [String: WipeOptions] { lock.withLock { wipedWith } }

    func currentDevice(id: String) async throws -> ManagedDevice {
        guard let found = devices[id] else { throw GraphError.notFound(detail: nil) }
        return found
    }

    func wipe(deviceID: String, options: WipeOptions, macOsUnlockCode: String?) async throws -> Int {
        lock.withLock { wipedWith[deviceID] = options }
        return 204
    }

    func retire(deviceID: String) async throws -> Int { 204 }
    func deleteRecord(deviceID: String) async throws -> Int { 204 }
}

private struct OkAuth: AuthVerifying {
    func verifyStillAuthenticated(scopes: [String]) async throws -> AdminSession {
        AdminSession(accountId: "a", username: "admin@contoso.com", displayName: nil, tenantId: "t")
    }
}

final class WindowsExecutorTests: XCTestCase {
    private func plan(wipe: WipeOptions) -> OffboardingPlan {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        selection.setWipeOptions(wipe, for: .managedDevice("d1"))
        return selection.makePlan(user: testUser, mode: .production, devices: [device("d1")], mamGroups: [])
    }

    private func run(_ plan: OffboardingPlan, devices: DeviceFake) async -> OffboardingResult {
        await ProductionExecutor(actions: devices, auth: OkAuth(), scopes: ["x"]).execute(plan) { _ in }
    }

    private func fixture() -> DeviceFake {
        let devices = DeviceFake()
        devices.devices["d1"] = device("d1")
        return devices
    }

    func testTheChosenWindowsOptionsAreWhatIsSent() async {
        let devices = fixture()
        let keep = WipeOptions(keepEnrollmentData: true)
        let result = await run(plan(wipe: keep), devices: devices)
        XCTAssertEqual(devices.wiped["d1"], keep)
        XCTAssertEqual(result.operations[0].state, .submitted)
        XCTAssertTrue(result.operations[0].message.contains("KEEPS enrollment data"))

        let full = fixture()
        _ = await run(plan(wipe: .fullWipe), devices: full)
        XCTAssertEqual(full.wiped["d1"], WipeOptions.fullWipe)
    }

    func testKeepOptionsAreNeverSentToADeviceThatIsNotWindows() async {
        // A plan built by hand (makePlan would not produce it): the executor must still refuse.
        let mac = device("m1", serial: "S", os: "macOS")
        let devices = DeviceFake()
        devices.devices["m1"] = mac
        let planned = PlannedAction(
            asset: .managedDevice("m1"), label: "Mac", action: .mdmWipe, ownership: nil, serialNumber: "S", apiOperation: "x",
            fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "PC m1"),
            wipeOptions: WipeOptions(keepEnrollmentData: true))
        let result = await run(OffboardingPlan(user: testUser, mode: .production, actions: [planned]), devices: devices)
        XCTAssertTrue(devices.wiped.isEmpty)
        XCTAssertEqual(result.operations[0].state, .failed)
        XCTAssertTrue(result.operations[0].message.contains("Windows devices only"))
    }
}
