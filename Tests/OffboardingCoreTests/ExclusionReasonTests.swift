import XCTest
@testable import OffboardingCore

final class ExclusionReasonTests: XCTestCase {
    private let user = EntraUser(id: "u1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: nil)

    private func device(_ json: String) -> ManagedDevice {
        try! GraphJSON.makeDecoder().decode(ManagedDevice.self, from: Data(json.utf8))
    }

    func testMissingUserIDIsExplained() {
        let reason = DeviceDiscoveryResult.exclusionReason(
            for: device(#"{"id":"d1","userPrincipalName":"john@contoso.com"}"#), user: user)
        XCTAssertTrue(reason.contains("no user ID"))
    }

    func testAllZerosUserIDMeansNoPrimaryUser() {
        let reason = DeviceDiscoveryResult.exclusionReason(
            for: device(#"{"id":"d1","userId":"00000000-0000-0000-0000-000000000000"}"#), user: user)
        XCTAssertTrue(reason.contains("no primary user"))
    }

    func testDifferentUserIDShowsBothIDsAndNotesAMatchingUPN() {
        let other = DeviceDiscoveryResult.exclusionReason(
            for: device(#"{"id":"d1","userId":"u9","userPrincipalName":"sam@contoso.com"}"#), user: user)
        XCTAssertTrue(other.contains("u9") && other.contains("u1") && other.contains("sam@contoso.com"))
        let sameUPN = DeviceDiscoveryResult.exclusionReason(
            for: device(#"{"id":"d1","userId":"u9","userPrincipalName":"JOHN@contoso.com"}"#), user: user)
        XCTAssertTrue(sameUPN.contains("user name matches"))
    }
}
