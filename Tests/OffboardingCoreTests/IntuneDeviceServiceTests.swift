import XCTest
@testable import OffboardingCore

final class IntuneDeviceServiceTests: XCTestCase {
    private let user = EntraUser(id: "user-1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: true)

    private func service(_ transport: MockTransport) -> IntuneDeviceService {
        IntuneDeviceService(graph: GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport))
    }

    /// Full record, as returned by GET /deviceManagement/managedDevices/{id}.
    private func device(_ id: String, name: String = "Mac", userId: String? = "user-1") -> String {
        let uid = userId.map { #","userId":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","deviceName":"\#(name)"\#(uid)}"#
    }

    /// Candidate as returned by the per-user list: only the id is requested.
    private func candidate(_ id: String) -> String { #"{"id":"\#(id)"}"# }

    private func page(_ items: [String], next: String? = nil) -> MockTransport.Reply {
        let link = next.map { #","@odata.nextLink":"\#($0)""# } ?? ""
        return .init(status: 200, body: #"{"value":[\#(items.joined(separator: ","))]\#(link)}"#)
    }

    private func record(_ json: String) -> Result<MockTransport.Reply, Error> { .success(.init(status: 200, body: json)) }

    func testListsCandidatesPerUserThenReadsEachFullRecord() async throws {
        let t = MockTransport([.success(page([candidate("d1")])), record(device("d1"))])
        _ = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(t.requests[0].url?.path, "/v1.0/users/user-1/managedDevices")
        XCTAssertTrue(t.requests[0].url!.absoluteString.hasSuffix("$select=id"))
        XCTAssertEqual(t.requests[1].url?.path, "/v1.0/deviceManagement/managedDevices/d1")
        XCTAssertTrue(t.requests[1].url!.absoluteString.contains("$select=id%2CuserId%2CdeviceName"))
    }

    /// The real-tenant case: the per-user list carries no user fields, the full record does.
    func testAssociationIsDecidedOnTheFullRecordNotTheList() async throws {
        let t = MockTransport([.success(page([candidate("d1")])), record(device("d1", userId: "user-1"))])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.map(\.id), ["d1"])
        XCTAssertTrue(result.excluded.isEmpty)
    }

    func testSameNameDevicesStayDistinctByID() async throws {
        let t = MockTransport([
            .success(page([candidate("b"), candidate("a")])),
            record(device("b", name: "MacBook")), record(device("a", name: "MacBook")),
        ])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.map(\.id), ["a", "b"])
    }

    func testDevicesNotTiedToUserAreExcluded() async throws {
        let t = MockTransport([
            .success(page([candidate("mine"), candidate("other"), candidate("none")])),
            record(device("mine")), record(device("other", userId: "someone-else")), record(device("none", userId: nil)),
        ])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.map(\.id), ["mine"])
        XCTAssertEqual(Set(result.excluded.map(\.id)), ["other", "none"])
    }

    func testUserIDComparisonIsCaseInsensitive() async throws {
        let t = MockTransport([.success(page([candidate("d1")])), record(device("d1", userId: "USER-1"))])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.count, 1)
    }

    func testPaginationAndDuplicateIDsReadEachDeviceOnce() async throws {
        let t = MockTransport([
            .success(page([candidate("d1")], next: "https://graph.microsoft.com/v1.0/users/user-1/managedDevices?$skiptoken=x")),
            .success(page([candidate("d1"), candidate("d2")])),
            record(device("d1")), record(device("d2")),
        ])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.map(\.id), ["d1", "d2"])
        XCTAssertEqual(t.requests.count, 4)
    }

    func testDeviceThatVanishedAfterTheListIsSkipped() async throws {
        let t = MockTransport([
            .success(page([candidate("gone"), candidate("d2")])),
            .success(.init(status: 404, body: "{}")), record(device("d2")),
        ])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.devices.map(\.id), ["d2"])
        XCTAssertTrue(result.excluded.isEmpty)
    }

    func testUnsafeCandidateIDIsNeverPutInAPathAndIsExcluded() async throws {
        let t = MockTransport([.success(page([candidate("../users")]))])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertEqual(result.excluded.map(\.id), ["../users"])
        XCTAssertEqual(t.requests.count, 1)
    }

    func testNoDevicesIsAnEmptyResultNotAnError() async throws {
        let t = MockTransport([.success(page([]))])
        let result = try await service(t).discoverDevices(for: user)
        XCTAssertTrue(result.devices.isEmpty)
    }

    func testRejectsUnexpectedUserID() async {
        let bad = EntraUser(id: "../x", displayName: nil, userPrincipalName: "a@b.com", accountEnabled: nil)
        let t = MockTransport([])
        do { _ = try await service(t).discoverDevices(for: bad); XCTFail() }
        catch { XCTAssertEqual(error as? DeviceDiscoveryError, .invalidUserID) }
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testForbiddenPropagatesFromListAndFromFullRead() async {
        let list = MockTransport([.success(.init(status: 403, body: "{}"))])
        do { _ = try await service(list).discoverDevices(for: user); XCTFail() }
        catch { XCTAssertEqual(error as? GraphError, .forbidden(detail: nil)) }

        let read = MockTransport([.success(page([candidate("d1")])), .success(.init(status: 403, body: "{}"))])
        do { _ = try await service(read).discoverDevices(for: user); XCTFail() }
        catch { XCTAssertEqual(error as? GraphError, .forbidden(detail: nil)) }
    }
}
