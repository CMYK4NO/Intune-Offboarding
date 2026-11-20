import XCTest
@testable import OffboardingCore

final class ModelDecodingTests: XCTestCase {
    private let decoder = GraphJSON.makeDecoder()

    func testManagedDeviceDecodesWithSevenDigitFractionAndOffset() throws {
        let json = """
        {"id":"dev-1","userId":"u-1","deviceName":"DT-MBP-1","managedDeviceOwnerType":"company",
         "enrolledDateTime":"2024-05-01T10:00:00.1234567Z","lastSyncDateTime":"2024-05-02T10:00:00-08:00",
         "operatingSystem":"macOS","complianceState":"compliant","managementState":"managed",
         "managementAgent":"mdm","serialNumber":"C02XXXX","azureADDeviceId":"aad-1"}
        """
        let device = try decoder.decode(ManagedDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.id, "dev-1")
        XCTAssertEqual(device.managedDeviceOwnerType, .company)
        XCTAssertEqual(device.managedDeviceOwnerType?.displayName, "Corporate")
        XCTAssertNotNil(device.enrolledDateTime)
        XCTAssertNotNil(device.lastSyncDateTime)
    }

    func testUnknownEnumValuesDoNotBreakDecoding() throws {
        let json = #"{"id":"d","managementState":"someFutureState","complianceState":"newState","managedDeviceOwnerType":"x"}"#
        let device = try decoder.decode(ManagedDevice.self, from: Data(json.utf8))
        XCTAssertEqual(device.managementState, .unrecognized)
        XCTAssertEqual(device.complianceState, .unknown)
        XCTAssertEqual(device.managedDeviceOwnerType, .unknown)
    }

    func testDevicesWithSameNameStayDistinctByID() throws {
        let a = try decoder.decode(ManagedDevice.self, from: Data(#"{"id":"a","deviceName":"Mac"}"#.utf8))
        let b = try decoder.decode(ManagedDevice.self, from: Data(#"{"id":"b","deviceName":"Mac"}"#.utf8))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    func testEntraUserDecodes() throws {
        let json = #"{"id":"u1","displayName":"John Doe","userPrincipalName":"john.doe@contoso.com","accountEnabled":false}"#
        let user = try decoder.decode(EntraUser.self, from: Data(json.utf8))
        XCTAssertEqual(user.userPrincipalName, "john.doe@contoso.com")
        XCTAssertEqual(user.accountEnabled, false)
    }

    func testMAMRegistrationDecodesIOSAndAndroidIdentifiers() throws {
        let ios = #"{"id":"m1","userId":"u1","appIdentifier":{"@odata.type":"microsoft.graph.iosMobileAppIdentifier","bundleId":"com.microsoft.Office.Outlook"},"deviceType":"iPhone"}"#
        let android = #"{"id":"m2","appIdentifier":{"@odata.type":"microsoft.graph.androidMobileAppIdentifier","packageId":"com.microsoft.teams"}}"#
        XCTAssertEqual(try decoder.decode(MAMRegistration.self, from: Data(ios.utf8)).appIdentifier?.displayValue,
                       "com.microsoft.Office.Outlook")
        XCTAssertEqual(try decoder.decode(MAMRegistration.self, from: Data(android.utf8)).appIdentifier?.displayValue,
                       "com.microsoft.teams")
    }

    func testDateParsingVariants() {
        XCTAssertNotNil(GraphJSON.parseDate("2024-05-01T10:00:00Z"))
        XCTAssertNotNil(GraphJSON.parseDate("2024-05-01T10:00:00.123Z"))
        XCTAssertNotNil(GraphJSON.parseDate("2024-05-01T10:00:00.1Z"))
        XCTAssertNil(GraphJSON.parseDate("not a date"))
    }
}
