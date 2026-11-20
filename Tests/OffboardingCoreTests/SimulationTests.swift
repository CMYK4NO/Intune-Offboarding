import XCTest
@testable import OffboardingCore

// MARK: - Fakes

private struct FakeUsers: UserResolving {
    var user: EntraUser
    func resolve(upn: String) async throws -> EntraUser { user }
}

private struct FakeDevices: DeviceDiscovering {
    var result: DeviceDiscoveryResult
    func discoverDevices(for user: EntraUser) async throws -> DeviceDiscoveryResult { result }
}

private struct FakeMAM: MAMDiscovering {
    var result: MAMDiscoveryResult
    func discoverRegistrations(for user: EntraUser) async throws -> MAMDiscoveryResult { result }
}

private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [OperationState] = []
    func add(_ s: OperationState) { lock.withLock { storage.append(s) } }
    var all: [OperationState] { lock.withLock { storage } }
}

final class SimulationTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ id: String, name: String = "Mac", serial: String = "S1", userId: String = "u1") -> ManagedDevice {
        try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(
            #"{"id":"\#(id)","deviceName":"\#(name)","serialNumber":"\#(serial)","userId":"\#(userId)","managedDeviceOwnerType":"company"}"#.utf8))
    }

    private func registration(_ id: String, tag: String) -> MAMRegistration {
        try! GraphJSON.makeDecoder().decode(MAMRegistration.self, from: Data(
            #"{"id":"\#(id)","userId":"u1","deviceTag":"\#(tag)","deviceName":"iPhone","appIdentifier":{"bundleId":"com.app.\#(id)"}}"#.utf8))
    }

    private func validator(devices: [ManagedDevice], excluded: [ManagedDevice] = [], regs: [MAMRegistration] = [],
                           user override: EntraUser? = nil) -> PlanValidator {
        PlanValidator(
            users: FakeUsers(user: override ?? user),
            devices: FakeDevices(result: DeviceDiscoveryResult(devices: devices, excluded: excluded)),
            mam: FakeMAM(result: MAMDiscoveryResult(registrations: regs, groups: MAMDeviceGroup.group(regs), excluded: [])))
    }

    // MARK: Selection

    func testEverythingDefaultsToNoActionAndEmptyPlan() {
        let selection = OffboardingSelection()
        let plan = selection.makePlan(user: user, mode: .simulation, devices: [device("d1")], mamGroups: [])
        XCTAssertEqual(selection.action(for: .managedDevice("d1")), .noAction)
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testInapplicableActionsAreIgnored() {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .mamDeviceGroup("g"))
        selection.set(.mamSelectiveWipe, for: .managedDevice("d1"))
        XCTAssertEqual(selection.action(for: .mamDeviceGroup("g")), .noAction)
        XCTAssertEqual(selection.action(for: .managedDevice("d1")), .noAction)
    }

    func testPlanCountsAndSeparationOfWipeAndDelete() {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        selection.set(.deleteIntuneRecord, for: .managedDevice("d2"))
        let groups = MAMDeviceGroup.group([registration("r1", tag: "t")])
        selection.set(.mamSelectiveWipe, for: .mamDeviceGroup("t"))
        let plan = selection.makePlan(user: user, mode: .simulation,
                                      devices: [device("d1"), device("d2"), device("d3")], mamGroups: groups)
        XCTAssertEqual(plan.wipeCount, 1)
        XCTAssertEqual(plan.deleteCount, 1)
        XCTAssertEqual(plan.selectiveWipeCount, 1)
        XCTAssertEqual(plan.actions.count, 3) // d3 stays No Action
    }

    func testChoiceForAssetNoLongerListedIsDropped() {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("gone"))
        let plan = selection.makePlan(user: user, mode: .simulation, devices: [device("d1")], mamGroups: [])
        XCTAssertTrue(plan.actions.isEmpty)
    }

    // MARK: Validation

    private func wipePlan() -> OffboardingPlan {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        return selection.makePlan(user: user, mode: .simulation, devices: [device("d1")], mamGroups: [])
    }

    func testUnchangedPlanValidates() async {
        let issues = await validator(devices: [device("d1")]).validate(wipePlan())
        XCTAssertTrue(issues.isEmpty)
    }

    func testDifferentUserBlocks() async {
        let other = EntraUser(id: "u2", displayName: nil, userPrincipalName: "john@contoso.com", accountEnabled: nil)
        let issues = await validator(devices: [device("d1")], user: other).validate(wipePlan())
        XCTAssertEqual(issues, [.userChanged])
    }

    func testMissingChangedAndReassignedDevicesBlock() async {
        let plan = wipePlan()
        let missing = await validator(devices: []).validate(plan)
        XCTAssertEqual(missing, [.deviceMissing("Mac")])
        let changed = await validator(devices: [device("d1", serial: "OTHER")]).validate(plan)
        XCTAssertEqual(changed, [.deviceChanged("Mac")])
        let reassigned = await validator(devices: [], excluded: [device("d1", userId: "u9")]).validate(plan)
        XCTAssertEqual(reassigned, [.deviceNoLongerAssociated("Mac")])
    }

    func testMAMGroupChangeBlocks() async {
        var selection = OffboardingSelection()
        selection.set(.mamSelectiveWipe, for: .mamDeviceGroup("t"))
        let reviewed = [registration("r1", tag: "t")]
        let plan = selection.makePlan(user: user, mode: .simulation, devices: [], mamGroups: MAMDeviceGroup.group(reviewed))
        let same = await validator(devices: [], regs: reviewed).validate(plan)
        XCTAssertTrue(same.isEmpty)
        let extra = await validator(devices: [], regs: reviewed + [registration("r2", tag: "t")]).validate(plan)
        XCTAssertEqual(extra.count, 1)
        let gone = await validator(devices: [], regs: []).validate(plan)
        XCTAssertEqual(gone.count, 1)
    }

    // MARK: Simulation

    func testSimulationNeverReportsSubmittedOrSucceeded() async {
        var selection = OffboardingSelection()
        selection.set(.mdmWipe, for: .managedDevice("d1"))
        selection.set(.deleteIntuneRecord, for: .managedDevice("d2"))
        let plan = selection.makePlan(user: user, mode: .simulation, devices: [device("d1"), device("d2")], mamGroups: [])
        let updates = Updates()
        let result = await SimulationExecutor().execute(plan) { updates.add($0.state) }
        XCTAssertEqual(result.mode, .simulation)
        XCTAssertEqual(result.summary, .simulated)
        XCTAssertTrue(result.operations.allSatisfy { $0.state == .skipped })
        XCTAssertTrue(result.operations.allSatisfy { $0.message.contains("No changes were made") })
        XCTAssertFalse(updates.all.contains(.submitted) || updates.all.contains(.succeeded))
        XCTAssertEqual(result.operations[0].apiOperation, "POST /deviceManagement/managedDevices/d1/wipe")
        XCTAssertEqual(result.operations[1].apiOperation, "DELETE /deviceManagement/managedDevices/d2")
    }
}
