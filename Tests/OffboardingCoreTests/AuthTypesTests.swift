import XCTest
@testable import OffboardingCore

final class AuthTypesTests: XCTestCase {
    func testErrorMessagesAreReadable() {
        XCTAssertTrue(AuthError.interactionRequired.localizedDescription.contains("sign in again"))
        XCTAssertTrue(AuthError.wrongTenant(expected: "A", actual: "B").localizedDescription.contains("A"))
        XCTAssertTrue(AuthError.cancelled.localizedDescription.contains("cancelled"))
    }

    func testFakeProviderSatisfiesProtocol() async throws {
        struct Fake: AccessTokenProviding {
            func accessToken(for scopes: [String]) async throws -> String { "t" }
        }
        let token = try await Fake().accessToken(for: ["User.Read"])
        XCTAssertEqual(token, "t")
    }
}
