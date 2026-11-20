import XCTest
@testable import OffboardingCore

final class UserServiceTests: XCTestCase {
    private func service(_ transport: MockTransport) -> UserService {
        UserService(graph: GraphClient(tokenProvider: StubTokens(), scopes: ["User.Read.All"], transport: transport))
    }

    private func page(_ users: [(id: String, upn: String)]) -> MockTransport.Reply {
        let items = users.map { #"{"id":"\#($0.id)","displayName":"X","userPrincipalName":"\#($0.upn)","accountEnabled":true}"# }
        return .init(status: 200, body: #"{"value":[\#(items.joined(separator: ","))]}"#)
    }

    func testResolvesExactMatchCaseInsensitively() async throws {
        let t = MockTransport([.success(page([("u1", "John.Doe@contoso.com")]))])
        let user = try await service(t).resolve(upn: "  john.doe@contoso.com ")
        XCTAssertEqual(user.id, "u1")
        XCTAssertFalse(t.requests[0].url!.absoluteString.contains("accountEnabled")) // outside User.ReadBasic.All
        XCTAssertTrue(t.requests[0].url!.absoluteString.contains("%24filter") || t.requests[0].url!.absoluteString.contains("$filter"))
    }

    func testInvalidUPNNeverCallsGraph() async {
        for bad in ["", "john", "john@", "@contoso.com", "john doe@contoso.com", "john@contoso"] {
            let t = MockTransport([])
            do { _ = try await service(t).resolve(upn: bad); XCTFail("accepted \(bad)") }
            catch { XCTAssertEqual(error as? UserLookupError, .invalidUPN) }
            XCTAssertTrue(t.requests.isEmpty)
        }
    }

    func testNotFound() async {
        let t = MockTransport([.success(page([]))])
        do { _ = try await service(t).resolve(upn: "no.one@contoso.com"); XCTFail() }
        catch { XCTAssertEqual(error as? UserLookupError, .notFound("no.one@contoso.com")) }
    }

    func testAmbiguousStops() async {
        let t = MockTransport([.success(page([("1", "a@b.com"), ("2", "a@b.com")]))])
        do { _ = try await service(t).resolve(upn: "a@b.com"); XCTFail() }
        catch { XCTAssertEqual(error as? UserLookupError, .ambiguous(2)) }
    }

    func testDifferentIdentityReturnedIsRejected() async {
        let t = MockTransport([.success(page([("1", "someone.else@b.com")]))])
        do { _ = try await service(t).resolve(upn: "a@b.com"); XCTFail() }
        catch { XCTAssertEqual(error as? UserLookupError, .mismatch) }
    }

    func testApostropheIsEscapedInFilter() async throws {
        let t = MockTransport([.success(page([("1", "o'brien@b.com")]))])
        _ = try await service(t).resolve(upn: "o'brien@b.com")
        XCTAssertTrue(t.requests[0].url!.absoluteString.contains("o%27%27brien"))
    }
}
