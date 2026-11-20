import XCTest
@testable import OffboardingCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct StubTokens: AccessTokenProviding {
    func accessToken(for scopes: [String]) async throws -> String { "test-token" }
}

final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var replies: [Result<Reply, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Result<Reply, Error>]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // withLock is the async-safe scoped form of NSLock.
        let next: Result<Reply, Error> = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .failure(URLError(.badServerResponse)) : replies.removeFirst()
        }
        let reply = try next.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ v: TimeInterval) { lock.lock(); values.append(v); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

final class GraphClientTests: XCTestCase {
    private func client(_ transport: MockTransport, delays: Delays = Delays(), attempts: Int = 3) -> GraphClient {
        GraphClient(tokenProvider: StubTokens(), scopes: ["User.Read.All"], transport: transport,
                    maxAttempts: attempts, sleep: { delays.add($0) })
    }

    func testSendsBearerTokenAndDecodes() async throws {
        let t = MockTransport([.success(.init(status: 200, body: #"{"id":"u1","userPrincipalName":"a@b.com"}"#))])
        let user: EntraUser = try await client(t).get("/users/u1")
        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(t.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testPaginationFollowsNextLink() async throws {
        let t = MockTransport([
            .success(.init(status: 200, body: #"{"value":[{"id":"1"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/x?$skiptoken=abc"}"#)),
            .success(.init(status: 200, body: #"{"value":[{"id":"2"}]}"#)),
        ])
        let devices: [ManagedDevice] = try await client(t).getAll("/deviceManagement/managedDevices")
        XCTAssertEqual(devices.map(\.id), ["1", "2"])
        XCTAssertEqual(t.requests.count, 2)
    }

    func testRefusesPagingLinkToOtherHost() async {
        let t = MockTransport([
            .success(.init(status: 200, body: #"{"value":[],"@odata.nextLink":"https://evil.example.com/steal"}"#)),
        ])
        do {
            let _: [ManagedDevice] = try await client(t).getAll("/x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .untrustedPagingLink("https://evil.example.com/steal"))
        }
        XCTAssertEqual(t.requests.count, 1) // token was never sent to the foreign host
    }

    func testThrottlingHonoursRetryAfterThenSucceeds() async throws {
        let delays = Delays()
        let t = MockTransport([
            .success(.init(status: 429, body: "{}", headers: ["Retry-After": "7"])),
            .success(.init(status: 200, body: #"{"id":"u1","userPrincipalName":"a@b.com"}"#)),
        ])
        let _: EntraUser = try await client(t, delays: delays).get("/users/u1")
        XCTAssertEqual(delays.all, [7])
    }

    func testServerErrorRetriesThenGivesUp() async {
        let t = MockTransport(Array(repeating: .success(.init(status: 503, body: "{}")), count: 3))
        do {
            let _: EntraUser = try await client(t).get("/users/u1")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .server(status: 503, detail: nil))
        }
        XCTAssertEqual(t.requests.count, 3)
    }

    func testForbiddenIsNotRetriedAndIsReadable() async {
        let t = MockTransport([.success(.init(status: 403, body: #"{"error":{"code":"Forbidden","message":"Insufficient privileges"}}"#))])
        do {
            let _: EntraUser = try await client(t).get("/users/u1")
            XCTFail("expected error")
        } catch let error as GraphError {
            XCTAssertEqual(error, .forbidden(detail: "Forbidden – Insufficient privileges"))
            XCTAssertTrue(error.localizedDescription.contains("does not have permission"))
        } catch { XCTFail("wrong error") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testNetworkErrorRetriesThenReports() async {
        let t = MockTransport(Array(repeating: .failure(URLError(.timedOut)), count: 2))
        do {
            let _: EntraUser = try await client(t, attempts: 2).get("/users/u1")
            XCTFail("expected error")
        } catch {
            guard case .network = error as? GraphError else { return XCTFail("wrong error") }
        }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testQueryEncodingIsStrict() throws {
        let url = try client(MockTransport([])).makeURL(path: "/users", query: [("$filter", "userPrincipalName eq 'a+b@x.com'")])
        XCTAssertTrue(url.absoluteString.contains("$filter=userPrincipalName%20eq%20%27a%2Bb%40x.com%27"))
    }

    func testBadJSONIsADecodingError() async {
        let t = MockTransport([.success(.init(status: 200, body: "not json"))])
        do {
            let _: EntraUser = try await client(t).get("/users/u1")
            XCTFail("expected error")
        } catch {
            guard case .decoding = error as? GraphError else { return XCTFail("wrong error") }
        }
    }
}
