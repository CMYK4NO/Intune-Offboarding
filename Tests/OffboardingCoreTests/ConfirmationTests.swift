import XCTest
@testable import OffboardingCore

final class ConfirmationTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func plan(_ actions: [(String, OffboardingAction)], mode: ExecutionMode = .production) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: mode, actions: actions.map { id, action in
            PlannedAction(asset: .managedDevice(id), label: "Mac \(id)", action: action, ownership: "Corporate",
                          serialNumber: "S-\(id)", apiOperation: action.apiDescription(assetID: id),
                          fingerprint: .device(userId: "u1", serialNumber: "S-\(id)", deviceName: "Mac \(id)"))
        })
    }

    func testDeleteOnlyNeedsAcknowledgementNotPhrase() {
        let policy = ConfirmationPolicy(plan: plan([("d1", .deleteIntuneRecord)]))
        XCTAssertTrue(policy.requiresSecondConfirmation)
        XCTAssertFalse(policy.requiresStrongConfirmation)
        XCTAssertNil(policy.requiredPhrase)
        XCTAssertFalse(policy.isSatisfied(acknowledged: false, typedPhrase: ""))
        XCTAssertTrue(policy.isSatisfied(acknowledged: true, typedPhrase: ""))
    }

    func testWipeNeedsAcknowledgementAndExactPhraseWithCount() {
        let policy = ConfirmationPolicy(plan: plan([("d1", .mdmWipe), ("d2", .mdmWipe), ("d3", .deleteIntuneRecord)]))
        XCTAssertTrue(policy.requiresStrongConfirmation)
        XCTAssertEqual(policy.requiredPhrase, "WIPE 2")
        XCTAssertFalse(policy.isSatisfied(acknowledged: true, typedPhrase: ""))
        XCTAssertFalse(policy.isSatisfied(acknowledged: true, typedPhrase: "wipe 2"))
        XCTAssertFalse(policy.isSatisfied(acknowledged: true, typedPhrase: "WIPE 1"))
        XCTAssertFalse(policy.isSatisfied(acknowledged: false, typedPhrase: "WIPE 2"))
        XCTAssertTrue(policy.isSatisfied(acknowledged: true, typedPhrase: " WIPE 2 "))
    }

    func testEmptyPlanIsNeverSatisfied() {
        XCTAssertFalse(ConfirmationPolicy(plan: plan([])).isSatisfied(acknowledged: true, typedPhrase: ""))
    }

    func testWarningWordingAndSimulationPrefix() {
        let one = ConfirmationPolicy(plan: plan([("d1", .mdmWipe)]))
        XCTAssertEqual(one.warning, "You are about to remotely wipe 1 device. "
            + "This action can permanently erase data from these devices and cannot be undone.")
        let two = ConfirmationPolicy(plan: plan([("d1", .mdmWipe), ("d2", .mdmWipe)], mode: .simulation))
        XCTAssertTrue(two.warning.hasPrefix("SIMULATION: You are about to remotely wipe 2 devices."))
    }

    func testConfirmationListsWipedAndDeletedDevicesDistinctly() {
        let policy = ConfirmationPolicy(plan: plan([("d1", .mdmWipe), ("d2", .deleteIntuneRecord)]))
        XCTAssertEqual(policy.destructiveDeviceLines.count, 2)
        XCTAssertTrue(policy.destructiveDeviceLines[0].hasPrefix("• Wipe: Mac d1"))
        XCTAssertTrue(policy.destructiveDeviceLines[1].hasPrefix("• Delete record: Mac d2"))
    }

    func testDeleteWarningMentionsRetireAndTitlesDifferFromWipe() {
        let delete = ConfirmationPolicy(plan: plan([("d1", .deleteIntuneRecord)]))
        XCTAssertTrue(delete.warning.contains("delete 1 device record from Intune"))
        XCTAssertTrue(delete.warning.contains("Retire"))
        XCTAssertFalse(delete.warning.contains("remotely wipe"))
        XCTAssertEqual(delete.alertTitle, "Delete 1 Intune record(s)?")
        XCTAssertEqual(ConfirmationPolicy(plan: plan([("d1", .mdmWipe)])).alertTitle, "Wipe 1 device(s)?")
        XCTAssertEqual(ConfirmationPolicy(plan: plan([("d1", .mdmWipe), ("d2", .deleteIntuneRecord)])).alertButtonTitle, "Run 2 actions")
        XCTAssertEqual(ConfirmationPolicy(plan: plan([("d1", .deleteIntuneRecord)], mode: .simulation)).alertButtonTitle, "Simulate")
    }
}
