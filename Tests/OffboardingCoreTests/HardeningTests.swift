import XCTest
@testable import OffboardingCore

/// Phase 12: cross-cutting safety checks that combine several action types.
final class HardeningTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ id: String, _ action: OffboardingAction) -> PlannedAction {
        PlannedAction(asset: .managedDevice(id), label: "Mac \(id)", action: action, ownership: "Corporate", serialNumber: "S-\(id)",
                      apiOperation: "x", fingerprint: .device(userId: "u1", serialNumber: "S-\(id)", deviceName: "Mac \(id)"))
    }

    private func selective(_ tag: String) -> PlannedAction {
        PlannedAction(asset: .mamDeviceGroup(tag), label: "iPhone \(tag)", action: .mamSelectiveWipe, ownership: nil, serialNumber: nil,
                      apiOperation: "x", fingerprint: .mamGroup(registrationIDs: ["r-\(tag)"]))
    }

    func testSelectiveWipeOnlyNeedsAcknowledgementAndGetsTheAlert() {
        let policy = ConfirmationPolicy(plan: OffboardingPlan(user: user, mode: .production, actions: [selective("a")]))
        XCTAssertTrue(policy.requiresSecondConfirmation)
        XCTAssertFalse(policy.requiresStrongConfirmation)
        XCTAssertNil(policy.requiredPhrase)
        XCTAssertTrue(policy.isSatisfied(acknowledged: true, typedPhrase: ""))
        XCTAssertFalse(policy.isSatisfied(acknowledged: false, typedPhrase: ""))
        XCTAssertTrue(policy.alertTitle.contains("app data"))
        XCTAssertTrue(policy.warning.contains("device itself is not erased"))
        XCTAssertEqual(policy.destructiveDeviceLines.count, 1)
    }

    func testMixedPlanStillNeedsThePhraseForWipesOnly() {
        let plan = OffboardingPlan(user: user, mode: .production, actions: [device("d1", .mdmWipe), selective("a"), device("d2", .deleteIntuneRecord)])
        let policy = ConfirmationPolicy(plan: plan)
        XCTAssertEqual(policy.requiredPhrase, "WIPE 1")
        XCTAssertEqual(policy.destructiveDeviceLines.count, 3)
        XCTAssertTrue(policy.alertTitle.contains("3"))
    }

    func testSelectiveWipesAreNotCountedInThePerRunCap() {
        let tags = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let plan = OffboardingPlan(user: user, mode: .production, actions: tags.map(selective) + [device("d1", .mdmWipe)])
        XCTAssertNil(plan.safetyViolation)
        XCTAssertTrue(ConfirmationPolicy(plan: plan).isSatisfied(acknowledged: true, typedPhrase: "WIPE 1"))
    }

    func testPerRunCapStillAppliesToDeviceActionsAlongsideSelectiveWipes() {
        let devices = ["d1", "d2", "d3", "d4", "d5", "d6"].map { device($0, .retireDevice) }
        let plan = OffboardingPlan(user: user, mode: .production, actions: devices + [selective("a")])
        XCTAssertNotNil(plan.safetyViolation)
        XCTAssertFalse(ConfirmationPolicy(plan: plan).isSatisfied(acknowledged: true, typedPhrase: ""))
    }

    func testSameGroupTwiceIsRefused() {
        let plan = OffboardingPlan(user: user, mode: .production, actions: [selective("a"), selective("a")])
        XCTAssertNotNil(plan.safetyViolation)
    }

    func testProductionExecutorRefusesOversizedMixedPlanBeforeAnyCall() async {
        struct Auth: AuthVerifying {
            func verifyStillAuthenticated(scopes: [String]) async throws -> AdminSession {
                XCTFail("session must not even be checked for a refused plan")
                throw AuthError.notSignedIn
            }
        }
        let devices = ["d1", "d2", "d3", "d4", "d5", "d6"].map { device($0, .deleteIntuneRecord) }
        let plan = OffboardingPlan(user: user, mode: .production, actions: devices + [selective("a")])
        let result = await ProductionExecutor(actions: NoDeviceActions(), mam: NoMAM(), auth: Auth(), scopes: ["x"]).execute(plan) { _ in }
        XCTAssertTrue(result.operations.allSatisfy { $0.state != .submitted && $0.state != .succeeded })
    }
}

private struct NoDeviceActions: DeviceActionPerforming {
    func currentDevice(id: String) async throws -> ManagedDevice { XCTFail("no call expected"); throw GraphError.notFound(detail: nil) }
    func wipe(deviceID: String, options: WipeOptions, macOsUnlockCode: String?) async throws -> Int { XCTFail("no call expected"); return 0 }
    func retire(deviceID: String) async throws -> Int { XCTFail("no call expected"); return 0 }
    func deleteRecord(deviceID: String) async throws -> Int { XCTFail("no call expected"); return 0 }
}

private struct NoMAM: MAMActionPerforming {
    func currentGroups(for user: EntraUser) async throws -> [MAMDeviceGroup] { XCTFail("no call expected"); return [] }
    func selectiveWipe(userID: String, deviceTag: String) async throws -> Int { XCTFail("no call expected"); return 0 }
}
