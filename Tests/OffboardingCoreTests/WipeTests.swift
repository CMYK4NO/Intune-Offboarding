import XCTest
@testable import OffboardingCore

// MARK: - GraphClient.post

final class GraphPostTests: XCTestCase {
    private func client(_ transport: MockTransport, delays: Delays = Delays()) -> GraphClient {
        GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport,
                    maxAttempts: 3, sleep: { delays.add($0) })
    }

    func testPostSendsOnceWithJSONBodyAndReturnsStatus() async throws {
        let t = MockTransport([.success(.init(status: 204, body: ""))])
        let status = try await client(t).post("/deviceManagement/managedDevices/abc-1/wipe", body: WipeRequestBody())
        XCTAssertEqual(status, 204)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].httpMethod, "POST")
        XCTAssertEqual(t.requests[0].url?.path, "/v1.0/deviceManagement/managedDevices/abc-1/wipe")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: t.requests[0].httpBody ?? Data()) as? [String: Bool]
        XCTAssertEqual(body, ["keepEnrollmentData": false, "keepUserData": false, "persistEsimDataPlan": false])
    }

    func testServerErrorIsOutcomeUnknownAndNeverRetried() async {
        let t = MockTransport([.success(.init(status: 503, body: "")), .success(.init(status: 204, body: ""))])
        let delays = Delays()
        do {
            try await client(t, delays: delays).post("/p", body: WipeRequestBody())
            XCTFail("expected error")
        } catch let error as GraphError {
            guard case .outcomeUnknown = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertTrue(delays.all.isEmpty)
    }

    func testTimeoutAfterSendIsOutcomeUnknownAndNeverRetried() async {
        let t = MockTransport([.failure(URLError(.timedOut)), .success(.init(status: 204, body: ""))])
        do {
            try await client(t).post("/p", body: WipeRequestBody())
            XCTFail("expected error")
        } catch let error as GraphError {
            guard case .outcomeUnknown = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("got \(error)") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testThrottledAndForbiddenAreDefiniteAndNotRetried() async {
        for (status, expected) in [(429, 429), (403, 403)] {
            let t = MockTransport([.success(.init(status: status, body: "")), .success(.init(status: 204, body: ""))])
            do {
                try await client(t).post("/p", body: WipeRequestBody())
                XCTFail("expected error")
            } catch let error as GraphError {
                XCTAssertEqual(error.httpStatus, expected)
            } catch { XCTFail("got \(error)") }
            XCTAssertEqual(t.requests.count, 1)
        }
    }
}

// MARK: - IntuneDeviceActionService

final class DeviceActionServiceTests: XCTestCase {
    func testRejectsUnsafeIDsWithoutSendingAnything() async {
        let t = MockTransport([])
        let service = IntuneDeviceActionService(graph: GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t))
        do { _ = try await service.wipe(deviceID: "../users/1", options: .fullWipe); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? DeviceActionError, .invalidDeviceID) }
        do { _ = try await service.currentDevice(id: "a b"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? DeviceActionError, .invalidDeviceID) }
        XCTAssertTrue(t.requests.isEmpty)
    }
}

// MARK: - ProductionExecutor

private final class FakeActions: DeviceActionPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var wiped: [String] = []
    private var wipeOptionsUsed: [String: WipeOptions] = [:]
    private var unlockCodesUsed: [String: String] = [:]
    var unlockCodes: [String: String] { lock.withLock { unlockCodesUsed } }
    private var fetched: [String] = []
    private var deleted: [String] = []
    private var retired: [String] = []
    var devices: [String: Result<ManagedDevice, Error>] = [:]
    var wipeResults: [String: Result<Int, Error>] = [:]
    var deleteResults: [String: Result<Int, Error>] = [:]
    /// When true (default) a successful delete makes the device answer 404 afterwards, like Intune.
    var removesOnDelete = true
    /// Ids whose delete takes effect even though the reply is an error (a lost reply).
    var removedDespiteError: Set<String> = []
    /// Test hook run at the start of every read (used to simulate a cancellation during re-verification).
    var onFetch: (@Sendable () -> Void)?

    var wipedIDs: [String] { lock.withLock { wiped } }
    var optionsSent: [String: WipeOptions] { lock.withLock { wipeOptionsUsed } }
    var fetchedIDs: [String] { lock.withLock { fetched } }
    var deletedIDs: [String] { lock.withLock { deleted } }
    var retiredIDs: [String] { lock.withLock { retired } }
    var retireResults: [String: Result<Int, Error>] = [:]

    func currentDevice(id: String) async throws -> ManagedDevice {
        lock.withLock { fetched.append(id) }
        onFetch?()
        return try (devices[id] ?? .failure(GraphError.notFound(detail: nil))).get()
    }

    func wipe(deviceID: String, options: WipeOptions, macOsUnlockCode: String?) async throws -> Int {
        lock.withLock { wiped.append(deviceID); wipeOptionsUsed[deviceID] = options; unlockCodesUsed[deviceID] = macOsUnlockCode }
        return try (wipeResults[deviceID] ?? .success(204)).get()
    }

    func retire(deviceID: String) async throws -> Int {
        lock.withLock { retired.append(deviceID) }
        return try (retireResults[deviceID] ?? .success(204)).get()
    }

    func deleteRecord(deviceID: String) async throws -> Int {
        lock.withLock { deleted.append(deviceID) }
        let result = deleteResults[deviceID] ?? .success(204)
        var applied = false
        if case .success = result { applied = true }
        if removedDespiteError.contains(deviceID) { applied = true }
        if removesOnDelete && applied { devices[deviceID] = .failure(GraphError.notFound(detail: nil)) }
        return try result.get()
    }
}

private struct FakeAuth: AuthVerifying {
    var error: Error?
    func verifyStillAuthenticated(scopes: [String]) async throws -> AdminSession {
        if let error { throw error }
        return AdminSession(accountId: "a", username: "admin@contoso.com", displayName: nil, tenantId: "t")
    }
}

final class ProductionExecutorTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ id: String, serial: String = "S", userId: String = "u1") -> ManagedDevice {
        try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(
            #"{"id":"\#(id)","deviceName":"Mac \#(id)","serialNumber":"\#(serial)","userId":"\#(userId)"}"#.utf8))
    }

    private func plan(_ items: [(String, OffboardingAction)]) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: .production, actions: items.map { id, action in
            PlannedAction(asset: .managedDevice(id), label: "Mac \(id)", action: action, ownership: nil, serialNumber: "S",
                          apiOperation: action.apiDescription(assetID: id),
                          fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Mac \(id)"))
        })
    }

    private func run(_ plan: OffboardingPlan, actions: FakeActions, auth: FakeAuth = FakeAuth()) async -> OffboardingResult {
        await ProductionExecutor(actions: actions, auth: auth, scopes: ["x"]).execute(plan) { _ in }
    }

    func testWipeIsSubmittedNotSucceeded() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .mdmWipe)]), actions: actions)
        XCTAssertEqual(result.mode, .production)
        XCTAssertEqual(actions.wipedIDs, ["d1"])
        XCTAssertEqual(result.operations[0].state, .submitted)
        XCTAssertEqual(result.operations[0].httpStatus, 204)
        XCTAssertTrue(result.operations[0].message.contains("does not mean the device has been erased"))
    }

    func testChangedOrReassignedOrMissingDeviceIsNeverWiped() async {
        let actions = FakeActions()
        actions.devices["serial"] = .success(device("serial", serial: "OTHER"))
        actions.devices["user"] = .success(device("user", userId: "u9"))
        // "gone" has no entry: the fake answers 404
        let result = await run(plan([("serial", .mdmWipe), ("user", .mdmWipe), ("gone", .mdmWipe)]), actions: actions)
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.failed, .failed, .failed])
        XCTAssertTrue(result.operations.allSatisfy { $0.message.contains("Nothing was sent") || $0.message.contains("nothing was sent") })
    }

    func testOversizedPlanIsRefusedAndNothingIsSent() async {
        let actions = FakeActions()
        let ids = (1...(OffboardingPlan.maxDestructiveActionsPerRun + 1)).map { "d\($0)" }
        for id in ids { actions.devices[id] = .success(device(id)) }
        let big = plan(ids.map { ($0, OffboardingAction.mdmWipe) })
        XCTAssertNotNil(big.safetyViolation)
        XCTAssertFalse(ConfirmationPolicy(plan: big).isSatisfied(acknowledged: true, typedPhrase: "WIPE \(ids.count)"))
        let result = await run(big, actions: actions)
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertTrue(actions.fetchedIDs.isEmpty)
        XCTAssertTrue(result.operations.allSatisfy { $0.state == .failed && $0.message.hasPrefix("Not sent") })
    }

    func testPlanAtTheLimitIsAllowed() {
        let ids = (1...OffboardingPlan.maxDestructiveActionsPerRun).map { "d\($0)" }
        XCTAssertNil(plan(ids.map { ($0, OffboardingAction.mdmWipe) }).safetyViolation)
    }

    func testDuplicateAssetIsRefusedSoADeviceCanNeverBeWipedTwice() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .mdmWipe), ("d1", .mdmWipe)]), actions: actions)
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.failed, .failed])
    }

    func testCancelledRunSendsNothing() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let p = plan([("d1", .mdmWipe)])
        let task = Task { () -> OffboardingResult in
            while !Task.isCancelled { await Task.yield() }
            return await self.run(p, actions: actions)
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .skipped)
    }

    func testExpiredSessionSendsNothing() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .mdmWipe)]), actions: actions, auth: FakeAuth(error: AuthError.interactionRequired))
        XCTAssertTrue(actions.fetchedIDs.isEmpty)
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .failed)
        XCTAssertEqual(result.summary, .failed)
    }

    func testOneFailureDoesNotAffectOthersAndUnknownOutcomeIsKept() async {
        let actions = FakeActions()
        for id in ["a", "b", "c"] { actions.devices[id] = .success(device(id)) }
        actions.wipeResults["a"] = .failure(GraphError.forbidden(detail: nil))
        actions.wipeResults["b"] = .failure(GraphError.outcomeUnknown("timed out"))
        let result = await run(plan([("a", .mdmWipe), ("b", .mdmWipe), ("c", .mdmWipe)]), actions: actions)
        XCTAssertEqual(result.operations.map(\.state), [.failed, .outcomeUnknown, .submitted])
        XCTAssertEqual(result.operations[0].httpStatus, 403)
        XCTAssertEqual(actions.wipedIDs, ["a", "b", "c"]) // each attempted exactly once
        XCTAssertEqual(result.summary, .completedWithWarnings)
    }

    func testSelectiveWipeIsSkippedAndNeverSent() async {
        let actions = FakeActions()
        let selective = PlannedAction(asset: .mamDeviceGroup("t"), label: "iPhone", action: .mamSelectiveWipe, ownership: nil,
                                      serialNumber: nil, apiOperation: "x", fingerprint: .mamGroup(registrationIDs: ["r"]))
        let result = await run(OffboardingPlan(user: user, mode: .production, actions: [selective]), actions: actions)
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertTrue(actions.deletedIDs.isEmpty)
        XCTAssertTrue(actions.fetchedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.skipped])
        XCTAssertEqual(result.summary, .notExecuted)
    }

    func testSubmittedPlusSkippedIsCompletedWithWarnings() async {
        let actions = FakeActions()
        actions.devices["a"] = .success(device("a"))
        let selective = PlannedAction(asset: .mamDeviceGroup("t"), label: "iPhone", action: .mamSelectiveWipe, ownership: nil,
                                      serialNumber: nil, apiOperation: "x", fingerprint: .mamGroup(registrationIDs: ["r"]))
        let base = plan([("a", .mdmWipe)])
        let result = await run(OffboardingPlan(user: user, mode: .production, actions: base.actions + [selective]), actions: actions)
        XCTAssertEqual(result.operations.map(\.state), [.submitted, .skipped])
        XCTAssertEqual(result.summary, .completedWithWarnings)
    }

    // MARK: Delete from Intune (Phase 9)

    func testDeleteSendsOneDeleteNeverAWipeAndIsConfirmedByA404() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .deleteIntuneRecord)]), actions: actions)
        XCTAssertEqual(actions.deletedIDs, ["d1"])
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .succeeded)
        XCTAssertEqual(result.operations[0].httpStatus, 204)
        XCTAssertTrue(result.operations[0].message.contains("not a device wipe"))
        XCTAssertEqual(actions.fetchedIDs, ["d1", "d1"]) // verify before, check after
    }

    func testWipeNeverTriggersADelete() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        _ = await run(plan([("d1", .mdmWipe)]), actions: actions)
        XCTAssertEqual(actions.wipedIDs, ["d1"])
        XCTAssertTrue(actions.deletedIDs.isEmpty)
    }

    func testWipeAndDeleteOnDifferentDevicesAreIndependent() async {
        let actions = FakeActions()
        actions.devices["w"] = .success(device("w"))
        actions.devices["x"] = .success(device("x"))
        actions.deleteResults["x"] = .failure(GraphError.forbidden(detail: nil))
        let result = await run(plan([("w", .mdmWipe), ("x", .deleteIntuneRecord)]), actions: actions)
        XCTAssertEqual(actions.wipedIDs, ["w"])
        XCTAssertEqual(actions.deletedIDs, ["x"])
        XCTAssertEqual(result.operations.map(\.state), [.submitted, .failed])
        XCTAssertEqual(result.operations[1].httpStatus, 403)
    }

    func testDeleteAcceptedButRecordStillThereIsSubmittedNotSucceeded() async {
        let actions = FakeActions()
        actions.removesOnDelete = false
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .deleteIntuneRecord)]), actions: actions)
        XCTAssertEqual(result.operations[0].state, .submitted)
        XCTAssertEqual(actions.deletedIDs, ["d1"])
    }

    func testChangedReassignedOrMissingDeviceIsNeverDeleted() async {
        let actions = FakeActions()
        actions.devices["serial"] = .success(device("serial", serial: "OTHER"))
        actions.devices["user"] = .success(device("user", userId: "u9"))
        let result = await run(plan([("serial", .deleteIntuneRecord), ("user", .deleteIntuneRecord), ("gone", .deleteIntuneRecord)]),
                               actions: actions)
        XCTAssertTrue(actions.deletedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.failed, .failed, .failed])
    }

    func testLostDeleteReplyIsNotRetriedAndIsSettledByOneRead() async {
        // Delete reached Intune but the reply was lost: one read shows the record is gone.
        let applied = FakeActions()
        applied.devices["d1"] = .success(device("d1"))
        applied.deleteResults["d1"] = .failure(GraphError.outcomeUnknown("timeout"))
        applied.removedDespiteError = ["d1"]
        let r1 = await run(plan([("d1", .deleteIntuneRecord)]), actions: applied)
        XCTAssertEqual(applied.deletedIDs, ["d1"]) // exactly one delete
        XCTAssertEqual(r1.operations[0].state, .succeeded)

        // Delete did not take effect: the record is still there, the outcome stays unknown, no second delete.
        let notApplied = FakeActions()
        notApplied.devices["d2"] = .success(device("d2"))
        notApplied.deleteResults["d2"] = .failure(GraphError.outcomeUnknown("HTTP 503"))
        let r2 = await run(plan([("d2", .deleteIntuneRecord)]), actions: notApplied)
        XCTAssertEqual(notApplied.deletedIDs, ["d2"])
        XCTAssertEqual(r2.operations[0].state, .outcomeUnknown)
        XCTAssertTrue(r2.operations[0].message.contains("NOT retried"))
    }

    func testExpiredSessionSendsNoDelete() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .deleteIntuneRecord)]), actions: actions, auth: FakeAuth(error: AuthError.interactionRequired))
        XCTAssertTrue(actions.deletedIDs.isEmpty)
        XCTAssertTrue(actions.fetchedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .failed)
    }
}

// MARK: - GraphClient.delete

final class GraphDeleteTests: XCTestCase {
    private func client(_ transport: MockTransport) -> GraphClient {
        GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport, maxAttempts: 3, sleep: { _ in })
    }

    func testDeleteSendsOneBodylessDeleteAndReturnsStatus() async throws {
        let t = MockTransport([.success(.init(status: 204, body: ""))])
        let status = try await client(t).delete("/deviceManagement/managedDevices/abc-1")
        XCTAssertEqual(status, 204)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(t.requests[0].url?.path, "/v1.0/deviceManagement/managedDevices/abc-1")
        XCTAssertNil(t.requests[0].httpBody)
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "Content-Type"))
    }

    func testDeleteServerErrorAndTimeoutAreOutcomeUnknownAndNeverRetried() async {
        for first in [Result<MockTransport.Reply, Error>.success(.init(status: 503, body: "")), .failure(URLError(.timedOut))] {
            let t = MockTransport([first, .success(.init(status: 204, body: ""))])
            do {
                try await client(t).delete("/p")
                XCTFail("expected error")
            } catch let error as GraphError {
                guard case .outcomeUnknown = error else { return XCTFail("got \(error)") }
            } catch { XCTFail("got \(error)") }
            XCTAssertEqual(t.requests.count, 1)
        }
    }

    func testDeleteForbiddenAndNotFoundAreDefiniteAndNotRetried() async {
        for status in [403, 404] {
            let t = MockTransport([.success(.init(status: status, body: "")), .success(.init(status: 204, body: ""))])
            do {
                try await client(t).delete("/p")
                XCTFail("expected error")
            } catch let error as GraphError {
                XCTAssertEqual(error.httpStatus, status)
            } catch { XCTFail("got \(error)") }
            XCTAssertEqual(t.requests.count, 1)
        }
    }

    func testServiceRejectsUnsafeIDsForDelete() async {
        let t = MockTransport([])
        let service = IntuneDeviceActionService(graph: client(t))
        do { _ = try await service.deleteRecord(deviceID: "../users/1"); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? DeviceActionError, .invalidDeviceID) }
        XCTAssertTrue(t.requests.isEmpty)
    }
}

// MARK: - MAM selective wipe (Phase 10)

private final class FakeMAM: MAMActionPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String)] = []
    var groups: Result<[MAMDeviceGroup], Error> = .success([])
    var wipeResult: Result<Int, Error> = .success(204)
    var onRead: (@Sendable () -> Void)?
    var wipeCalls: [(String, String)] { lock.withLock { calls } }

    func currentGroups(for user: EntraUser) async throws -> [MAMDeviceGroup] { onRead?(); return try groups.get() }
    func selectiveWipe(userID: String, deviceTag: String) async throws -> Int {
        lock.withLock { calls.append((userID, deviceTag)) }
        return try wipeResult.get()
    }
}

private struct StubDiscovery: MAMDiscovering {
    let registrations: [MAMRegistration]
    func discoverRegistrations(for user: EntraUser) async throws -> MAMDiscoveryResult {
        MAMDiscoveryResult(registrations: registrations, groups: MAMDeviceGroup.group(registrations), excluded: [])
    }
}

final class MAMSelectiveWipeTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func registration(_ id: String, tag: String?) -> MAMRegistration {
        let tagJSON = tag.map { #","deviceTag":"\#($0)""# } ?? ""
        return try! GraphJSON.makeDecoder().decode(MAMRegistration.self, from: Data(
            #"{"id":"\#(id)","userId":"u1","deviceName":"iPhone"\#(tagJSON)}"#.utf8))
    }

    private func planned(tag: String, ids: [String]) -> PlannedAction {
        PlannedAction(asset: .mamDeviceGroup(tag), label: "iPhone", action: .mamSelectiveWipe, ownership: nil,
                      serialNumber: nil, apiOperation: "x", fingerprint: .mamGroup(registrationIDs: ids.sorted()))
    }

    private func run(_ action: PlannedAction, mam: FakeMAM, auth: FakeAuth = FakeAuth()) async -> OffboardingResult {
        await ProductionExecutor(actions: FakeActions(), mam: mam, auth: auth, scopes: ["x"])
            .execute(OffboardingPlan(user: user, mode: .production, actions: [action])) { _ in }
    }

    func testMatchingGroupIsSubmittedOnceNotSucceeded() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: "T"), registration("r2", tag: "T")]))
        let result = await run(planned(tag: "T", ids: ["r1", "r2"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.submitted])
        XCTAssertEqual(result.operations.first?.httpStatus, 204)
        XCTAssertEqual(mam.wipeCalls.count, 1)
        XCTAssertEqual(mam.wipeCalls.first?.0, "u1")
        XCTAssertEqual(mam.wipeCalls.first?.1, "T")
    }

    func testChangedRegistrationsSendNothing() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: "T"), registration("r3", tag: "T")]))
        let result = await run(planned(tag: "T", ids: ["r1", "r2"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.failed])
        XCTAssertTrue(mam.wipeCalls.isEmpty)
    }

    func testMissingGroupSendsNothing() async {
        let mam = FakeMAM()
        let result = await run(planned(tag: "T", ids: ["r1"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.failed])
        XCTAssertTrue(mam.wipeCalls.isEmpty)
    }

    func testGroupWithoutTagIsRefused() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: nil)]))
        let result = await run(planned(tag: "registration:r1", ids: ["r1"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.failed])
        XCTAssertTrue(mam.wipeCalls.isEmpty)
    }

    func testRereadFailureSendsNothing() async {
        let mam = FakeMAM()
        mam.groups = .failure(GraphError.forbidden(detail: nil))
        let result = await run(planned(tag: "T", ids: ["r1"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.failed])
        XCTAssertTrue(mam.wipeCalls.isEmpty)
    }

    func testLostReplyIsOutcomeUnknownAndNotRetried() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: "T")]))
        mam.wipeResult = .failure(GraphError.outcomeUnknown("timeout"))
        let result = await run(planned(tag: "T", ids: ["r1"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.outcomeUnknown])
        XCTAssertEqual(mam.wipeCalls.count, 1)
    }

    func testForbiddenIsAFailureWithStatus() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: "T")]))
        mam.wipeResult = .failure(GraphError.forbidden(detail: nil))
        let result = await run(planned(tag: "T", ids: ["r1"]), mam: mam)
        XCTAssertEqual(result.operations.map(\.state), [.failed])
        XCTAssertEqual(result.operations.first?.httpStatus, 403)
    }

    func testExpiredSessionSendsNothing() async {
        let mam = FakeMAM()
        mam.groups = .success(MAMDeviceGroup.group([registration("r1", tag: "T")]))
        let result = await run(planned(tag: "T", ids: ["r1"]), mam: mam, auth: FakeAuth(error: AuthError.notSignedIn))
        XCTAssertTrue(mam.wipeCalls.isEmpty)
        XCTAssertNotEqual(result.operations.first?.state, .submitted)
    }

    func testServiceReadsRegistrationsFromDiscovery() async throws {
        let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: MockTransport([]))
        let service = MAMActionService(graph: graph, discovery: StubDiscovery(registrations: [registration("r1", tag: "T")]))
        let groups = try await service.currentGroups(for: user)
        XCTAssertEqual(groups.map(\.id), ["T"])
    }

    func testServiceRejectsUnsafeUserID() async {
        let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: MockTransport([]))
        let service = MAMActionService(graph: graph, discovery: StubDiscovery(registrations: []))
        do {
            _ = try await service.selectiveWipe(userID: "../x", deviceTag: "T")
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? DeviceActionError, .invalidDeviceID)
        }
    }
}

final class MAMSelectiveWipeWireTests: XCTestCase {
    func testPostsDeviceTagToTheV1UserAction() async throws {
        let t = MockTransport([.success(.init(status: 204, body: ""))])
        let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t)
        let service = MAMActionService(graph: graph, discovery: StubDiscovery(registrations: []))
        let status = try await service.selectiveWipe(userID: "u1", deviceTag: "TAG-1")
        XCTAssertEqual(status, 204)
        XCTAssertEqual(t.requests.count, 1)
        let request = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://graph.microsoft.com/v1.0/users/u1/wipeManagedAppRegistrationsByDeviceTag")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), #"{"deviceTag":"TAG-1"}"#)
    }
}

// MARK: - Cancellation right before sending (review of Phase 12)

final class CancellationGateTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ id: String) -> ManagedDevice {
        try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(
            #"{"id":"\#(id)","deviceName":"Mac \#(id)","serialNumber":"S","userId":"u1"}"#.utf8))
    }

    private func devicePlan(_ action: OffboardingAction) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: .production, actions: [
            PlannedAction(asset: .managedDevice("a"), label: "Mac a", action: action, ownership: "Corporate", serialNumber: "S",
                          apiOperation: "x", fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Mac a"))])
    }

    func testWipeIsNotSentIfTheRunIsCancelledDuringReverification() async {
        let actions = FakeActions()
        actions.devices["a"] = .success(device("a"))
        actions.onFetch = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(devicePlan(.mdmWipe)) { _ in }
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.skipped])
    }

    func testDeleteIsNotSentIfTheRunIsCancelledDuringReverification() async {
        let actions = FakeActions()
        actions.devices["a"] = .success(device("a"))
        actions.onFetch = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(devicePlan(.deleteIntuneRecord)) { _ in }
        XCTAssertTrue(actions.deletedIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.skipped])
    }

    func testSelectiveWipeIsNotSentIfTheRunIsCancelledDuringReverification() async {
        let mam = FakeMAM()
        let registration = try! GraphJSON.makeDecoder().decode(MAMRegistration.self, from: Data(
            #"{"id":"r1","userId":"u1","deviceName":"iPhone","deviceTag":"T"}"#.utf8))
        mam.groups = .success(MAMDeviceGroup.group([registration]))
        mam.onRead = { withUnsafeCurrentTask { $0?.cancel() } }
        let plan = OffboardingPlan(user: user, mode: .production, actions: [
            PlannedAction(asset: .mamDeviceGroup("T"), label: "iPhone", action: .mamSelectiveWipe, ownership: nil, serialNumber: nil,
                          apiOperation: "x", fingerprint: .mamGroup(registrationIDs: ["r1"]))])
        let result = await ProductionExecutor(actions: FakeActions(), mam: mam, auth: FakeAuth(), scopes: ["x"]).execute(plan) { _ in }
        XCTAssertTrue(mam.wipeCalls.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.skipped])
    }
}

// MARK: - Retire

final class RetireTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ id: String, serial: String = "S", userId: String = "u1") -> ManagedDevice {
        try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(
            #"{"id":"\#(id)","deviceName":"Mac \#(id)","serialNumber":"\#(serial)","userId":"\#(userId)"}"#.utf8))
    }

    private func plan(_ items: [(String, OffboardingAction)]) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: .production, actions: items.map { id, action in
            PlannedAction(asset: .managedDevice(id), label: "Mac \(id)", action: action, ownership: "Corporate", serialNumber: "S",
                          apiOperation: action.apiDescription(assetID: id),
                          fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Mac \(id)"))
        })
    }

    private func run(_ plan: OffboardingPlan, actions: FakeActions, auth: FakeAuth = FakeAuth()) async -> OffboardingResult {
        await ProductionExecutor(actions: actions, auth: auth, scopes: ["x"]).execute(plan) { _ in }
    }

    func testRetireIsOfferedBetweenWipeAndDeleteAndIsNotTheDefault() {
        XCTAssertEqual(OffboardingAction.available(for: .managedDevice), [.noAction, .mdmWipe, .retireDevice, .deleteIntuneRecord])
        XCTAssertNotEqual(OffboardingAction.default, .retireDevice)
        XCTAssertFalse(OffboardingAction.retireDevice.requiresStrongConfirmation)
        XCTAssertEqual(OffboardingAction.retireDevice.apiDescription(assetID: "d1"), "POST /deviceManagement/managedDevices/d1/retire")
    }

    func testRetireIsSubmittedOnceAndNeverAWipeOrDelete() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        let result = await run(plan([("d1", .retireDevice)]), actions: actions)
        XCTAssertEqual(actions.retiredIDs, ["d1"])
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertTrue(actions.deletedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .submitted) // pending until the device checks in
        XCTAssertEqual(result.operations[0].httpStatus, 204)
        XCTAssertTrue(result.operations[0].message.contains("next checks in"))
    }

    func testChangedOrReassignedDeviceIsNeverRetired() async {
        let actions = FakeActions()
        actions.devices["a"] = .success(device("a", serial: "OTHER"))
        actions.devices["b"] = .success(device("b", userId: "someone-else"))
        let result = await run(plan([("a", .retireDevice), ("b", .retireDevice), ("gone", .retireDevice)]), actions: actions)
        XCTAssertTrue(actions.retiredIDs.isEmpty)
        XCTAssertEqual(result.operations.map(\.state), [.failed, .failed, .failed])
    }

    func testLostRetireReplyIsUnknownAndNotRetried() async {
        let actions = FakeActions()
        actions.devices["d1"] = .success(device("d1"))
        actions.retireResults["d1"] = .failure(GraphError.outcomeUnknown("timeout"))
        let result = await run(plan([("d1", .retireDevice)]), actions: actions)
        XCTAssertEqual(actions.retiredIDs, ["d1"])
        XCTAssertEqual(result.operations[0].state, .outcomeUnknown)
        XCTAssertTrue(result.operations[0].message.contains("NOT retried"))
    }

    func testRetireNeedsTheSecondConfirmationButNoTypedPhrase() {
        let policy = ConfirmationPolicy(plan: plan([("d1", .retireDevice)]))
        XCTAssertTrue(policy.requiresSecondConfirmation)
        XCTAssertNil(policy.requiredPhrase)
        XCTAssertEqual(policy.alertTitle, "Retire 1 device(s)?")
        XCTAssertEqual(policy.alertButtonTitle, "Retire 1 device(s)")
        XCTAssertTrue(policy.warning.contains("retire 1 device"))
        XCTAssertEqual(policy.destructiveDeviceLines, ["• Retire: Mac d1 (Corporate, serial S)"])
        let mixed = ConfirmationPolicy(plan: plan([("w", .mdmWipe), ("r", .retireDevice)]))
        XCTAssertEqual(mixed.alertButtonTitle, "Run 2 actions")
        XCTAssertEqual(mixed.requiredPhrase, "WIPE 1")
    }

    func testServiceSendsOneBodylessPostToRetire() async throws {
        let t = MockTransport([.success(.init(status: 204, body: ""))])
        let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t)
        let status = try await IntuneDeviceActionService(graph: graph).retire(deviceID: "abc-1")
        XCTAssertEqual(status, 204)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(t.requests[0].httpMethod, "POST")
        XCTAssertEqual(t.requests[0].url?.path, "/v1.0/deviceManagement/managedDevices/abc-1/retire")
        XCTAssertNil(t.requests[0].httpBody)
        do {
            _ = try await IntuneDeviceActionService(graph: graph).retire(deviceID: "../x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DeviceActionError, .invalidDeviceID)
        }
        XCTAssertEqual(t.requests.count, 1)
    }
}

// MARK: - Pending action at send time

final class PendingActionExecutorTests: XCTestCase {
    func testAWipeIsNotSentWhileAnotherWipeIsStillPending() async throws {
        let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)
        let json = #"{"id":"d1","deviceName":"Mac d1","serialNumber":"S","userId":"u1","deviceActionResults":[{"actionName":"wipe","actionState":"pending"}]}"#
        let actions = FakeActions()
        actions.devices["d1"] = .success(try GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(json.utf8)))
        let plan = OffboardingPlan(user: user, mode: .production, actions: [
            PlannedAction(asset: .managedDevice("d1"), label: "Mac d1", action: .mdmWipe, ownership: "Corporate",
                          serialNumber: "S", apiOperation: "x",
                          fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Mac d1")),
        ])
        let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(plan) { _ in }
        XCTAssertTrue(actions.wipedIDs.isEmpty)
        XCTAssertEqual(result.operations[0].state, .failed)
        XCTAssertTrue(result.operations[0].message.contains("Nothing was sent"))
    }
}

// MARK: - Mac unlock PIN

final class MacUnlockCodeTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(os: String, extra: String = "") throws -> ManagedDevice {
        let json = #"{"id":"d1","deviceName":"Dev","serialNumber":"S","userId":"u1","operatingSystem":"\#(os)"\#(extra)}"#
        return try GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(json.utf8))
    }

    private func wipePlan() -> OffboardingPlan {
        OffboardingPlan(user: user, mode: .production, actions: [
            PlannedAction(asset: .managedDevice("d1"), label: "Dev", action: .mdmWipe, ownership: "Corporate",
                          serialNumber: "S", apiOperation: "x",
                          fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Dev")),
        ])
    }

    func testGeneratedCodesAreSixDigits() {
        for _ in 0..<200 { XCTAssertTrue(MacUnlockCode.isValid(MacUnlockCode.generate())) }
        for bad in ["12345", "1234567", "12a456", "١٢٣٤٥٦", ""] { XCTAssertFalse(MacUnlockCode.isValid(bad)) }
    }

    func testAMacWipeCarriesAPinAndShowsItWithoutPuttingItInTheMessage() async throws {
        let actions = FakeActions()
        actions.devices["d1"] = .success(try device(os: "macOS"))
        let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(wipePlan()) { _ in }
        let pin = try XCTUnwrap(actions.unlockCodes["d1"])
        XCTAssertTrue(MacUnlockCode.isValid(pin))
        XCTAssertEqual(result.operations[0].macOsUnlockCode, pin)
        XCTAssertFalse(result.operations[0].message.contains(pin)) // the message goes to the audit file
    }

    func testOtherPlatformsGetNoPin() async throws {
        for os in ["Windows", "iOS", "Android"] {
            let actions = FakeActions()
            actions.devices["d1"] = .success(try device(os: os))
            let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(wipePlan()) { _ in }
            XCTAssertEqual(actions.wipedIDs, ["d1"])
            XCTAssertNil(actions.unlockCodes["d1"], os)
            XCTAssertNil(result.operations[0].macOsUnlockCode)
        }
    }

    func testThePinIsInTheRequestBodyOnlyWhenGiven() async throws {
        let t = MockTransport([.success(.init(status: 204, body: "")), .success(.init(status: 204, body: ""))])
        let service = IntuneDeviceActionService(graph: GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t))
        _ = try await service.wipe(deviceID: "d1", options: .fullWipe, macOsUnlockCode: "123456")
        _ = try await service.wipe(deviceID: "d2", options: .fullWipe)
        let withPin = try JSONSerialization.jsonObject(with: t.requests[0].httpBody ?? Data()) as? [String: Any]
        let without = try JSONSerialization.jsonObject(with: t.requests[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(withPin?["macOsUnlockCode"] as? String, "123456")
        XCTAssertNil(without?["macOsUnlockCode"])
        do {
            _ = try await service.wipe(deviceID: "d3", options: .fullWipe, macOsUnlockCode: "12345")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DeviceActionError, .invalidUnlockCode)
        }
        XCTAssertEqual(t.requests.count, 2) // an invalid PIN is never sent
    }

    func testIntunesFailedStateUnblocksAStuckPendingWipe() throws {
        // The real Mac: action entry still "pending", management state already "wipeFailed".
        let stuck = try device(os: "macOS", extra: #","managementState":"wipeFailed","deviceActionResults":[{"actionName":"wipe","actionState":"pending"}]"#)
        XCTAssertNil(stuck.blockingReason(for: .mdmWipe))
        let pending = try device(os: "macOS", extra: #","managementState":"managed","deviceActionResults":[{"actionName":"wipe","actionState":"pending"}]"#)
        XCTAssertNotNil(pending.blockingReason(for: .mdmWipe))
    }
}

// MARK: - Intune registration check after a 204

final class IntuneRegistrationTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)
    private let sentAt = ISO8601DateFormatter().date(from: "2026-11-18T13:35:00Z")!

    private func device(_ id: String = "d1", extra: String) throws -> ManagedDevice {
        let json = #"{"id":"\#(id)","deviceName":"Dev","serialNumber":"S","userId":"u1","operatingSystem":"iOS"\#(extra)}"#
        return try GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(json.utf8))
    }

    private func plan(_ items: [(String, OffboardingAction)]) -> OffboardingPlan {
        OffboardingPlan(user: user, mode: .production, actions: items.map { id, action in
            PlannedAction(asset: .managedDevice(id), label: "Dev", action: action, ownership: "Corporate", serialNumber: "S",
                          apiOperation: "x", fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Dev"))
        })
    }

    func testAFreshEntryCountsAndAnOldPendingOneDoesNot() throws {
        let fresh = try device(extra: #","deviceActionResults":[{"actionName":"wipe","actionState":"pending","startDateTime":"2026-11-18T13:35:02Z"}]"#)
        XCTAssertEqual(fresh.registration(of: .mdmWipe, sentAt: sentAt).0, .registered)

        // The real Mac: only the wipe from an hour earlier, still "pending".
        let stale = try device(extra: #","managementState":"wipeFailed","deviceActionResults":[{"actionName":"wipe","actionState":"pending","startDateTime":"2026-11-18T12:34:15Z"}]"#)
        let (outcome, note) = stale.registration(of: .mdmWipe, sentAt: sentAt)
        XCTAssertEqual(outcome, .notRegistered)
        XCTAssertTrue(note.hasPrefix("WARNING"))
    }

    func testFailedOrMissingInformationIsReportedAsSuch() throws {
        let failed = try device(extra: #","deviceActionResults":[{"actionName":"retire","actionState":"failed","startDateTime":"2026-11-18T13:35:05Z"}]"#)
        XCTAssertEqual(failed.registration(of: .retireDevice, sentAt: sentAt).0, .failedInIntune)
        XCTAssertEqual(try device(extra: "").registration(of: .mdmWipe, sentAt: sentAt).0, .unverified)
        let clockSkew = try device(extra: #","deviceActionResults":[{"actionName":"wipe","actionState":"pending","startDateTime":"2026-11-18T13:34:00Z"}]"#)
        XCTAssertEqual(clockSkew.registration(of: .mdmWipe, sentAt: sentAt).0, .registered) // within 2 minutes
    }

    func testTheExecutorWaitsOnceThenReadsEachDeviceBackWithoutResending() async throws {
        let actions = FakeActions()
        // "done" rather than "pending": the fake returns the same record before and after, and a pending wipe
        // would (correctly) stop the send.
        let future = #","deviceActionResults":[{"actionName":"wipe","actionState":"done","startDateTime":"2100-01-01T00:00:00Z"}]"#
        actions.devices["a"] = .success(try device("a", extra: future))
        actions.devices["b"] = .success(try device("b", extra: #","deviceActionResults":[]"#))
        let delays = Delays()
        let executor = ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"], verificationDelay: 10,
                                          sleep: { delays.add($0) })
        let result = await executor.execute(plan([("a", .mdmWipe), ("b", .mdmWipe)])) { _ in }
        XCTAssertEqual(delays.all, [10])                        // one wait for the whole run
        XCTAssertEqual(actions.wipedIDs, ["a", "b"])            // nothing resent
        XCTAssertEqual(actions.fetchedIDs, ["a", "b", "a", "b"]) // verify before, read back after
        XCTAssertEqual(result.operations.map(\.state), [.submitted, .submitted])
        XCTAssertEqual(result.operations[0].intuneRegistration, .registered)
        XCTAssertEqual(result.operations[1].intuneRegistration, .notRegistered)
        XCTAssertTrue(result.operations[1].message.contains("Intune shows no new wipe"))
        XCTAssertFalse(result.operations[1].message.contains("Checking with Intune"))
    }

    func testNothingIsCheckedWhenNothingWasAccepted() async throws {
        let actions = FakeActions()
        actions.devices["a"] = .success(try device("a", extra: ""))
        actions.wipeResults["a"] = .failure(GraphError.forbidden(detail: nil))
        let delays = Delays()
        let executor = ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"], verificationDelay: 10,
                                          sleep: { delays.add($0) })
        let result = await executor.execute(plan([("a", .mdmWipe)])) { _ in }
        XCTAssertTrue(delays.all.isEmpty)
        XCTAssertNil(result.operations[0].intuneRegistration)
        XCTAssertEqual(actions.fetchedIDs, ["a"])
    }
}

final class RecordRemovedTests: XCTestCase {
    func testA404AfterTheRequestReadsAsRecordRemovedNotAsAFailure() async throws {
        let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)
        let json = #"{"id":"a","deviceName":"Dev","serialNumber":"S","userId":"u1","operatingSystem":"Windows"}"#
        let actions = FakeActions()
        actions.devices["a"] = .success(try GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(json.utf8)))
        // First read (before sending) finds the device; the read-back after the wipe finds it gone, as on the real Mac.
        actions.onFetch = { if actions.fetchedIDs.count >= 2 { actions.devices["a"] = .failure(GraphError.notFound(detail: nil)) } }
        let plan = OffboardingPlan(user: user, mode: .production, actions: [
            PlannedAction(asset: .managedDevice("a"), label: "Dev", action: .mdmWipe, ownership: "Corporate", serialNumber: "S",
                          apiOperation: "x", fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "Dev")),
        ])
        let result = await ProductionExecutor(actions: actions, auth: FakeAuth(), scopes: ["x"]).execute(plan) { _ in }
        XCTAssertEqual(actions.wipedIDs, ["a"])
        XCTAssertEqual(result.operations[0].state, .submitted)
        XCTAssertEqual(result.operations[0].intuneRegistration, .recordRemoved)
        XCTAssertTrue(result.operations[0].message.contains("already removed this device record"))
        XCTAssertFalse(result.operations[0].message.contains("Could not read"))
    }
}
