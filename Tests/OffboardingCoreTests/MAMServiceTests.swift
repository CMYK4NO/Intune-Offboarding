import XCTest
@testable import OffboardingCore

final class MAMServiceTests: XCTestCase {
    private let user = EntraUser(id: "user-1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: true)

    private func service(_ transport: MockTransport) -> MAMService {
        MAMService(graph: GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport))
    }

    private func reg(_ id: String, app: String = "com.microsoft.Office.Outlook", tag: String? = nil,
                     name: String? = nil, userId: String? = "user-1", flagged: [String]? = nil) -> String {
        var fields = [#""id":"\#(id)""#, #""appIdentifier":{"bundleId":"\#(app)"}"#]
        if let userId { fields.append(#""userId":"\#(userId)""#) }
        if let tag { fields.append(#""deviceTag":"\#(tag)""#) }
        if let name { fields.append(#""deviceName":"\#(name)""#) }
        if let flagged { fields.append(#""flaggedReasons":[\#(flagged.map { "\"\($0)\"" }.joined(separator: ","))]"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func page(_ items: [String]) -> MockTransport.Reply {
        .init(status: 200, body: #"{"value":[\#(items.joined(separator: ","))]}"#)
    }

    func testQueriesUserRelationshipWithoutSelect() async throws {
        let t = MockTransport([.success(page([reg("r1")]))])
        _ = try await service(t).discoverRegistrations(for: user)
        let url = t.requests[0].url!
        XCTAssertEqual(url.path, "/v1.0/users/user-1/managedAppRegistrations")
        XCTAssertNil(url.query)
    }

    func testRegistrationsOnSameDeviceTagAreGrouped() async throws {
        let t = MockTransport([.success(page([
            reg("r1", app: "com.microsoft.Office.Outlook", tag: "tagA", name: "Personal iPhone"),
            reg("r2", app: "com.microsoft.skype.teams", tag: "tagA", name: "Personal iPhone"),
            reg("r3", tag: "tagB", name: "iPad"),
        ]))])
        let result = try await service(t).discoverRegistrations(for: user)
        XCTAssertEqual(result.registrations.count, 3)
        XCTAssertEqual(result.groups.count, 2)
        let iphone = try XCTUnwrap(result.groups.first { $0.deviceTag == "tagA" })
        XCTAssertEqual(iphone.appIdentifiers, ["com.microsoft.Office.Outlook", "com.microsoft.skype.teams"])
    }

    func testUntaggedRegistrationsAreNeverMergedByName() async throws {
        let t = MockTransport([.success(page([reg("r1", name: "iPhone"), reg("r2", name: "iPhone")]))])
        let result = try await service(t).discoverRegistrations(for: user)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertTrue(result.groups.allSatisfy { $0.deviceTag == nil })
    }

    func testRegistrationsOfOtherUsersAreExcluded() async throws {
        let t = MockTransport([.success(page([reg("mine"), reg("other", userId: "someone"), reg("none", userId: nil)]))])
        let result = try await service(t).discoverRegistrations(for: user)
        XCTAssertEqual(result.registrations.map(\.id), ["mine"])
        XCTAssertEqual(Set(result.excluded.map(\.id)), ["other", "none"])
    }

    func testFlaggedReasonsAreDetected() async throws {
        let t = MockTransport([.success(page([reg("r1", flagged: ["rootedDevice"]), reg("r2", flagged: ["none"])]))])
        let result = try await service(t).discoverRegistrations(for: user)
        XCTAssertEqual(result.registrations.filter(\.isFlagged).map(\.id), ["r1"])
    }

    func testNoRegistrationsIsEmptyNotError() async throws {
        let t = MockTransport([.success(page([]))])
        let result = try await service(t).discoverRegistrations(for: user)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testRejectsUnexpectedUserIDAndPropagatesForbidden() async {
        let bad = EntraUser(id: "a/b", displayName: nil, userPrincipalName: "a@b.com", accountEnabled: nil)
        let none = MockTransport([])
        do { _ = try await service(none).discoverRegistrations(for: bad); XCTFail() }
        catch { XCTAssertEqual(error as? MAMDiscoveryError, .invalidUserID) }
        XCTAssertTrue(none.requests.isEmpty)

        let denied = MockTransport([.success(.init(status: 403, body: "{}"))])
        do { _ = try await service(denied).discoverRegistrations(for: user); XCTFail() }
        catch { XCTAssertEqual(error as? GraphError, .forbidden(detail: nil)) }
    }
}
