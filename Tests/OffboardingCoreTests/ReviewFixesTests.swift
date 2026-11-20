import XCTest
@testable import OffboardingCore

/// Regression tests for the second code review.
final class RetryAfterTests: XCTestCase {
    private func client(_ transport: MockTransport, delays: Delays = Delays()) -> GraphClient {
        GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: transport,
                    sleep: { delays.add($0) })
    }

    func testOnlySaneNonNegativeNumbersAreAccepted() {
        XCTAssertEqual(GraphClient.retryAfter("7"), 7)
        XCTAssertEqual(GraphClient.retryAfter(" 7 "), 7)
        XCTAssertEqual(GraphClient.retryAfter("0"), 0)
        for bad in [nil, "", "soon", "-5", "nan", "inf", "-inf"] {
            XCTAssertNil(GraphClient.retryAfter(bad), "\(bad ?? "nil") must be ignored")
        }
    }

    func testAnUnusableHeaderFallsBackToTheNormalBackoff() async throws {
        let delays = Delays()
        let t = MockTransport([
            .success(.init(status: 429, body: "{}", headers: ["Retry-After": "-1"])),
            .success(.init(status: 200, body: #"{"id":"u1","userPrincipalName":"a@b.com"}"#)),
        ])
        let _: EntraUser = try await client(t, delays: delays).get("/users/u1")
        XCTAssertEqual(delays.all, [GraphClient.backoff(1)])
    }

    func testAWaitLongerThanTheLimitIsReportedInsteadOfSlept() async {
        let delays = Delays()
        let t = MockTransport([.success(.init(status: 429, body: "{}", headers: ["Retry-After": "3600"]))])
        do {
            let _: EntraUser = try await client(t, delays: delays).get("/users/u1")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .throttled(retryAfter: 3600))
        }
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertTrue(delays.all.isEmpty)
    }

    func testAThrottledWriteIsNeverRetried() async {
        let t = MockTransport([.success(.init(status: 429, body: "{}", headers: ["Retry-After": "nan"]))])
        do {
            _ = try await client(t).delete("/deviceManagement/managedDevices/d1")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .throttled(retryAfter: nil))
        }
        XCTAssertEqual(t.requests.count, 1)
    }
}

final class PagingLinkTests: XCTestCase {
    func testLinksWithAnotherPortOrEmbeddedCredentialsAreRefused() async {
        for link in ["https://graph.microsoft.com:8443/v1.0/x", "https://user@graph.microsoft.com/v1.0/x",
                     "https://user:pw@graph.microsoft.com/v1.0/x", "http://graph.microsoft.com/v1.0/x"] {
            let t = MockTransport([.success(.init(status: 200, body: #"{"value":[],"@odata.nextLink":"\#(link)"}"#))])
            let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t)
            do {
                let _: [ManagedDevice] = try await graph.getAll("/x")
                XCTFail("\(link) must be refused")
            } catch {
                XCTAssertEqual(error as? GraphError, .untrustedPagingLink(link))
            }
            XCTAssertEqual(t.requests.count, 1)
        }
    }
}

final class AuditIdTests: XCTestCase {
    private func record(device: String, name: String = "MacBook") -> AuditRecord {
        AuditRecord(event: .operation, runId: "r1", timestamp: Date(timeIntervalSince1970: 100), mode: "production",
                    adminUPN: "a@x.com", adminObjectId: "o", tenantId: "t", targetUPN: "u@x.com", targetUserId: "1",
                    assetName: name, managedDeviceId: device)
    }

    func testTwoDevicesWithTheSameNameGetDifferentIds() {
        XCTAssertNotEqual(record(device: "d1").id, record(device: "d2").id)
        XCTAssertEqual(record(device: "d1").id, record(device: "d1").id)
    }
}

final class PagingGuardTests: XCTestCase {
    func testARepeatingNextLinkIsStoppedInsteadOfLoopingForever() async {
        let link = "https://graph.microsoft.com/v1.0/x?page=2"
        let t = MockTransport([
            .success(.init(status: 200, body: #"{"value":[],"@odata.nextLink":"\#(link)"}"#)),
            .success(.init(status: 200, body: #"{"value":[],"@odata.nextLink":"\#(link)"}"#)),
            .success(.init(status: 200, body: #"{"value":[],"@odata.nextLink":"\#(link)"}"#)),
        ])
        let graph = GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t)
        do {
            let _: [ManagedDevice] = try await graph.getAll("/x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GraphError, .tooManyPages)
        }
        XCTAssertEqual(t.requests.count, 2) // first page, then the repeated link once; never a third time
    }

    func testMultiAdminApprovalAnswerIsExplained() {
        XCTAssertTrue(GraphError.http(status: 412, detail: nil).localizedDescription.contains("Multi Admin Approval"))
        XCTAssertFalse(GraphError.http(status: 400, detail: nil).localizedDescription.contains("Multi Admin Approval"))
    }
}
