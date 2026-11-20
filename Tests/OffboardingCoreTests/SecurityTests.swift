import XCTest
@testable import OffboardingCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SecurityTests: XCTestCase {
    func testGraphIDAcceptsGuidsAndRejectsAnythingElse() {
        XCTAssertTrue(GraphID.isSafe("3f2c1a9e-1111-4a2b-9c3d-0123456789ab"))
        XCTAssertTrue(GraphID.isSafe("d1"))
        for bad in ["", "abc\n", "abc\n\n", " abc", "a/b", "..", "a.b", "a?b", "a#b", "a%2Fb", "é", String(repeating: "a", count: 65)] {
            XCTAssertFalse(GraphID.isSafe(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testPathChecksNoLongerAcceptATrailingNewline() {
        XCTAssertFalse(IntuneDeviceActionService.isPathSafe("abc\n"))
        XCTAssertFalse(MAMActionService.isPathSafe("abc\n"))
        XCTAssertFalse(EntraUser(id: "abc\n", displayName: nil, userPrincipalName: "a@b.com", accountEnabled: nil).hasPathSafeID)
    }

    func testRedirectsAreRefused() {
        var followed: URLRequest? = URLRequest(url: URL(string: "https://example.com")!)
        let task = URLSession.shared.dataTask(with: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        let response = HTTPURLResponse(url: URL(string: "https://graph.microsoft.com/v1.0/me")!, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": "https://evil.example.com"])!
        NoRedirectDelegate().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                        newRequest: URLRequest(url: URL(string: "https://evil.example.com")!)) { followed = $0 }
        XCTAssertNil(followed)
    }

    func testNonCorporateWipeIsFlaggedInTheConfirmation() {
        let user = EntraUser(id: "u1", displayName: nil, userPrincipalName: "a@b.com", accountEnabled: nil)
        func planned(_ ownership: String?) -> PlannedAction {
            PlannedAction(asset: .managedDevice("d"), label: "iPhone", action: .mdmWipe, ownership: ownership, serialNumber: "S",
                          apiOperation: "x", fingerprint: .device(userId: "u1", serialNumber: "S", deviceName: "iPhone"))
        }
        let personal = ConfirmationPolicy(plan: OffboardingPlan(user: user, mode: .production, actions: [planned("Personal")]))
        XCTAssertTrue(personal.destructiveDeviceLines[0].contains("NOT CORPORATE-OWNED"))
        let unknown = ConfirmationPolicy(plan: OffboardingPlan(user: user, mode: .production, actions: [planned(nil)]))
        XCTAssertTrue(unknown.destructiveDeviceLines[0].contains("NOT CORPORATE-OWNED"))
        let corporate = ConfirmationPolicy(plan: OffboardingPlan(user: user, mode: .production, actions: [planned("Corporate")]))
        XCTAssertFalse(corporate.destructiveDeviceLines[0].contains("NOT CORPORATE-OWNED"))
    }
}
