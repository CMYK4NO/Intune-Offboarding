import XCTest
@testable import OffboardingCore

final class AuditTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)
    private let admin = AdminSession(accountId: "a", username: "admin@contoso.com", displayName: nil, tenantId: "tenant-1")

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
    }

    private func plan(mode: ExecutionMode = .production) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: mode, actions: [
            PlannedAction(asset: .managedDevice("d1"), label: "Mac", action: .mdmWipe, ownership: "corporate", serialNumber: "SER1",
                          apiOperation: "POST wipe", fingerprint: .device(userId: "u1", serialNumber: "SER1", deviceName: "Mac")),
            PlannedAction(asset: .mamDeviceGroup("T"), label: "iPhone", action: .mamSelectiveWipe, ownership: nil, serialNumber: nil,
                          apiOperation: "POST wipeByTag", fingerprint: .mamGroup(registrationIDs: ["r1", "r2"])),
        ])
    }

    private func lines(_ dir: URL) throws -> [[String: Any]] {
        let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first!
        return try String(contentsOf: file).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    func testWritesStartAndPerOperationRecords() async throws {
        let dir = tempDir()
        let service = AuditService(directory: dir)
        let p = plan()
        let runId = await service.recordRunStarted(plan: p, admin: admin)!
        let result = OffboardingResult(mode: .production, operations: [
            OperationResult(asset: .managedDevice("d1"), assetLabel: "Mac", action: .mdmWipe, state: .submitted, httpStatus: 204, message: "ok"),
            OperationResult(asset: .mamDeviceGroup("T"), assetLabel: "iPhone", action: .mamSelectiveWipe, state: .failed, httpStatus: 403, message: "no"),
        ])
        await service.recordRun(runId: runId, plan: p, result: result, admin: admin)
        let rows = try lines(dir)
        XCTAssertEqual(rows.map { $0["event"] as? String }, ["runStarted", "operation", "operation"])
        XCTAssertEqual(Set(rows.compactMap { $0["runId"] as? String }), [runId])
        XCTAssertEqual(rows[1]["managedDeviceId"] as? String, "d1")
        XCTAssertEqual(rows[1]["serialNumber"] as? String, "SER1")
        XCTAssertEqual(rows[1]["httpStatus"] as? Int, 204)
        XCTAssertEqual(rows[1]["result"] as? String, "submitted")
        XCTAssertEqual(rows[1]["mode"] as? String, "production")
        XCTAssertEqual(rows[1]["adminUPN"] as? String, "admin@contoso.com")
        XCTAssertEqual(rows[1]["adminObjectId"] as? String, "a")
        XCTAssertEqual(rows[1]["tenantId"] as? String, "tenant-1")
        XCTAssertEqual(rows[1]["targetUPN"] as? String, "john@contoso.com")
        XCTAssertEqual(rows[1]["targetUserId"] as? String, "u1")
        XCTAssertEqual(rows[2]["mamRegistrationIds"] as? [String], ["r1", "r2"])
        XCTAssertEqual(rows[2]["httpStatus"] as? Int, 403)
    }

    func testAppendsAcrossRuns() async throws {
        let dir = tempDir()
        let service = AuditService(directory: dir)
        _ = await service.recordRunStarted(plan: plan(mode: .simulation), admin: admin)
        _ = await service.recordRunStarted(plan: plan(), admin: admin)
        let rows = try lines(dir)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["mode"] as? String, "simulation")
    }

    func testCredentialsInMessagesAreRedacted() async throws {
        let dir = tempDir()
        let service = AuditService(directory: dir)
        let p = plan()
        let runId = await service.recordRunStarted(plan: p, admin: admin)!
        let result = OffboardingResult(mode: .production, operations: [
            OperationResult(asset: .managedDevice("d1"), assetLabel: "Mac", action: .mdmWipe, state: .failed,
                            message: "Authorization: Bearer abc.def.ghi access_token=SECRET123"),
        ])
        await service.recordRun(runId: runId, plan: p, result: result, admin: admin)
        let text = try String(contentsOf: FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)[0])
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertFalse(text.contains("abc.def.ghi"))
    }

    func testLoadRecordsReturnsNewestFirstAndSkipsGarbage() async throws {
        let dir = tempDir()
        let service = AuditService(directory: dir)
        let p = plan()
        let runId = await service.recordRunStarted(plan: p, admin: admin)!
        let result = OffboardingResult(mode: .production, operations: [
            OperationResult(asset: .managedDevice("d1"), assetLabel: "Mac", action: .mdmWipe, state: .submitted, httpStatus: 204),
        ])
        await service.recordRun(runId: runId, plan: p, result: result, admin: admin)
        let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)[0]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("not json\n".utf8)); try handle.close()
        let loaded = AuditService.loadRecords(from: dir)
        XCTAssertEqual(loaded.map(\.event), [.operation, .runStarted])
        XCTAssertEqual(loaded.first?.httpStatus, 204)
        XCTAssertTrue(AuditService.loadRecords(from: dir.appendingPathComponent("missing")).isEmpty)
    }

    func testUnwritableDirectoryDoesNotThrowOrCrash() async {
        let service = AuditService(directory: URL(fileURLWithPath: "/dev/null/nope"))
        let runId = await service.recordRunStarted(plan: plan(), admin: admin)
        XCTAssertNil(runId, "a run start that could not be written must be reported, so production can be refused")
    }
}

final class AuditReadTests: XCTestCase {
    func testRecentRecordsReturnsNewestFirstAndRespectsLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-read-\(UUID().uuidString)")
        let service = AuditService(directory: dir)
        let user = EntraUser(id: "u1", displayName: nil, userPrincipalName: "a@b.com", accountEnabled: nil)
        let admin = AdminSession(accountId: "a", username: "admin@b.com", displayName: nil, tenantId: "t")
        let plan = OffboardingPlan(user: user, mode: .simulation, actions: [])
        let first = await service.recordRunStarted(plan: plan, admin: admin)!
        let second = await service.recordRunStarted(plan: plan, admin: admin)!
        let all = await service.recentRecords(limit: 10)
        XCTAssertEqual(all.map(\.runId), [second, first])
        let one = await service.recentRecords(limit: 1)
        XCTAssertEqual(one.map(\.runId), [second])
    }

    func testMissingDirectoryGivesNoRecords() async {
        let service = AuditService(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        let records = await service.recentRecords(limit: 5)
        XCTAssertTrue(records.isEmpty)
    }
}
