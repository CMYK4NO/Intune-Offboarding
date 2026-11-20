import XCTest
@testable import OffboardingCore

/// `deviceActionResults`: show what Intune has not finished, and never stack a clashing action on it.
final class PendingActionTests: XCTestCase {
    private func device(actions: String? = nil, state: String? = nil) throws -> ManagedDevice {
        var fields = [#""id":"d1""#, #""userId":"u1""#, #""deviceName":"Mac""#]
        if let actions { fields.append(#""deviceActionResults":\#(actions)"#) }
        if let state { fields.append(#""managementState":"\#(state)""#) }
        return try GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    func testDecodesTheDocumentedShapeAndToleratesBadEntries() throws {
        let d = try device(actions: #"""
            [{"actionName":"wipe","actionState":"pending","startDateTime":"2026-11-18T01:30:45.7156189Z","lastUpdatedDateTime":"2026-11-18T01:30:45Z"},
             {"actionName":"rebootNow","actionState":"done","startDateTime":"not a date"},
             "garbage"]
            """#)
        XCTAssertEqual(d.deviceActionResults?.count, 3)
        XCTAssertEqual(d.deviceActionResults?[0].actionName, "wipe")
        XCTAssertNotNil(d.deviceActionResults?[0].startDateTime)
        XCTAssertNil(d.deviceActionResults?[1].startDateTime) // bad date: field dropped, device still decoded
        XCTAssertNil(try device().deviceActionResults)         // list calls do not return it
    }

    func testPendingWipeBlocksWipeRetireAndDelete() throws {
        let d = try device(actions: #"[{"actionName":"Wipe","actionState":"pending","startDateTime":"2026-11-18T01:30:45Z"}]"#)
        XCTAssertNotNil(d.blockingReason(for: .mdmWipe))
        XCTAssertNotNil(d.blockingReason(for: .retireDevice))
        XCTAssertNotNil(d.blockingReason(for: .deleteIntuneRecord)) // deleting would drop the wipe
        XCTAssertNil(d.blockingReason(for: .noAction))
        XCTAssertTrue(d.blockingReason(for: .mdmWipe)!.hasPrefix("Wipe pending since"))
    }

    func testPendingRetireStillAllowsDelete() throws {
        let d = try device(actions: #"[{"actionName":"retire","actionState":"active"}]"#)
        XCTAssertNotNil(d.blockingReason(for: .mdmWipe))
        XCTAssertNotNil(d.blockingReason(for: .retireDevice))
        XCTAssertNil(d.blockingReason(for: .deleteIntuneRecord))
    }

    func testFinishedFailedOrUnrelatedActionsBlockNothing() throws {
        let d = try device(actions: #"""
            [{"actionName":"wipe","actionState":"failed"},{"actionName":"wipe","actionState":"done"},
             {"actionName":"rebootNow","actionState":"pending"}]
            """#)
        for action in OffboardingAction.available(for: .managedDevice) { XCTAssertNil(d.blockingReason(for: action)) }
    }

    func testManagementStateIsASecondSource() throws {
        XCTAssertNotNil(try device(state: "wipePending").blockingReason(for: .mdmWipe))
        XCTAssertNotNil(try device(state: "wipeIssued").blockingReason(for: .deleteIntuneRecord))
        XCTAssertNil(try device(state: "retirePending").blockingReason(for: .deleteIntuneRecord))
        XCTAssertNil(try device(state: "managed").blockingReason(for: .mdmWipe))
    }

    func testRecentActionsAreNewestFirstAndCapped() throws {
        let d = try device(actions: #"""
            [{"actionName":"a","actionState":"done","lastUpdatedDateTime":"2026-01-01T00:00:00Z"},
             {"actionName":"b","actionState":"done","lastUpdatedDateTime":"2026-03-01T00:00:00Z"},
             {"actionName":"c","actionState":"done","lastUpdatedDateTime":"2026-02-01T00:00:00Z"},
             {"actionName":"d","actionState":"done"}]
            """#)
        XCTAssertEqual(d.recentActions.map(\.actionName), ["b", "c", "a"])
    }

    func testDetailReadsRequestTheProperty() {
        XCTAssertTrue(ManagedDevice.graphSelect.contains("deviceActionResults"))
    }
}
