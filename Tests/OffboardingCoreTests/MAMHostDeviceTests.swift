import XCTest
@testable import OffboardingCore

/// App-protection registrations shown per phone (beta Entra device ID) while actions stay per device tag.
final class MAMHostDeviceTests: XCTestCase {
    private let user = EntraUser(id: "user-1", displayName: "John", userPrincipalName: "john@contoso.com", accountEnabled: true)

    private func json(_ id: String, tag: String?, app: String = "com.app", type: String = "iPhone",
                      os: String = "27.2.1", sync: String = "2026-11-20T10:00:00Z") -> String {
        var fields = [#""id":"\#(id)""#, #""userId":"user-1""#, #""deviceName":"iPhone""#, #""deviceType":"\#(type)""#,
                      #""platformVersion":"\#(os)""#, #""lastSyncDateTime":"\#(sync)""#, #""appIdentifier":{"bundleId":"\#(app)"}"#]
        if let tag { fields.append(#""deviceTag":"\#(tag)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func detail(_ id: String, entra: String?, model: String? = "iPhone18,2", maker: String? = "Apple") -> String {
        var fields = [#""id":"\#(id)""#]
        if let entra { fields.append(#""azureADDeviceId":"\#(entra)""#) }
        if let model { fields.append(#""deviceModel":"\#(model)""#) }
        if let maker { fields.append(#""deviceManufacturer":"\#(maker)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func page(_ items: [String]) -> MockTransport.Reply {
        .init(status: 200, body: #"{"value":[\#(items.joined(separator: ","))]}"#)
    }

    private func client(_ t: MockTransport, beta: Bool = false) -> GraphClient {
        GraphClient(tokenProvider: StubTokens(), scopes: ["x"], transport: t,
                    baseURL: beta ? GraphClient.betaBase : GraphClient.v1Base, maxAttempts: 1, sleep: { _ in })
    }

    private func registration(_ id: String, tag: String?, entra: String?, model: String? = "iPhone18,2",
                              os: String = "27.2.1", sync: String = "2026-11-20T10:00:00Z") -> MAMRegistration {
        var r = try! GraphJSON.makeDecoder().decode(MAMRegistration.self, from: Data(json(id, tag: tag, os: os, sync: sync).utf8))
        r.azureADDeviceId = entra
        r.deviceModel = model
        r.deviceManufacturer = "Apple"
        return r
    }

    // MARK: Discovery

    func testTagsOnTheSamePhoneAreShownAsOneDevice() async throws {
        let v1 = MockTransport([.success(page([json("r1", tag: "A"), json("r2", tag: "B"), json("r3", tag: "C")]))])
        let beta = MockTransport([.success(page([detail("r1", entra: "E1"), detail("r2", entra: "E1"),
                                                 detail("r3", entra: "E2", model: "iPhone15,3")]))])
        let service = MAMService(graph: client(v1), details: BetaMAMDeviceDetailsService(graph: client(beta, beta: true)))
        let result = try await service.discoverRegistrations(for: user)

        XCTAssertEqual(beta.requests.first?.url?.path, "/beta/users/user-1/managedAppRegistrations")
        XCTAssertEqual(result.groups.count, 3, "actions stay per device tag")
        XCTAssertEqual(result.hosts.count, 2)
        let phone = try XCTUnwrap(result.hosts.first { $0.entraDeviceId == "e1" })
        XCTAssertEqual(phone.groups.map(\.deviceTag), ["A", "B"])
        XCTAssertEqual(phone.title, "iPhone 17 Pro Max")
        XCTAssertEqual(phone.osDescription, "iOS 27.2.1")
        XCTAssertFalse(result.deviceDetailsUnavailable)
    }

    func testBetaFailureFallsBackToOneEntryPerTag() async throws {
        let v1 = MockTransport([.success(page([json("r1", tag: "A"), json("r2", tag: "B")]))])
        let beta = MockTransport([.success(.init(status: 403, body: "{}"))])
        let service = MAMService(graph: client(v1), details: BetaMAMDeviceDetailsService(graph: client(beta, beta: true)))
        let result = try await service.discoverRegistrations(for: user)
        XCTAssertTrue(result.deviceDetailsUnavailable)
        XCTAssertEqual(result.registrations.count, 2)
        XCTAssertEqual(result.hosts.count, 2)
    }

    func testBetaDetailsNeverAddOrReassignRegistrations() async throws {
        let v1 = MockTransport([.success(page([json("r1", tag: "A")]))])
        let beta = MockTransport([.success(page([detail("r1", entra: "E1"), detail("not-in-v1", entra: "E1")]))])
        let service = MAMService(graph: client(v1), details: BetaMAMDeviceDetailsService(graph: client(beta, beta: true)))
        let result = try await service.discoverRegistrations(for: user)
        XCTAssertEqual(result.registrations.map(\.id), ["r1"])
        XCTAssertEqual(result.hosts.first?.registrations.map(\.id), ["r1"])
    }

    func testWithoutDetailsProviderOnlyV1IsCalled() async throws {
        let v1 = MockTransport([.success(page([json("r1", tag: "A")]))])
        let result = try await MAMService(graph: client(v1)).discoverRegistrations(for: user)
        XCTAssertEqual(v1.requests.count, 1)
        XCTAssertFalse(result.deviceDetailsUnavailable)
    }

    // MARK: Grouping

    func testGroupsWithoutOrWithConflictingEntraIDAreNotMerged() {
        let groups = MAMDeviceGroup.group([
            registration("r1", tag: "A", entra: "E1"),
            registration("r2", tag: "B", entra: nil),          // unknown: own device
            registration("r3", tag: "C", entra: "E1"),
            registration("r4", tag: "C", entra: "E9"),          // tag C disagrees: own device
        ])
        let hosts = MAMHostDevice.group(groups)
        XCTAssertEqual(hosts.count, 3)
        XCTAssertEqual(hosts.first { $0.entraDeviceId == "e1" }?.groups.map(\.id), ["A"])
    }

    func testNewestSyncDecidesOSVersion() {
        let groups = MAMDeviceGroup.group([
            registration("old", tag: "A", entra: "E1", os: "26.6.2", sync: "2026-09-12T18:51:00Z"),
            registration("new", tag: "B", entra: "E1", os: "27.2.1", sync: "2026-11-20T11:00:00Z"),
        ])
        XCTAssertEqual(MAMHostDevice.group(groups).first?.platformVersion, "27.2.1")
    }

    func testModelNames() {
        XCTAssertEqual(DeviceModelNames.marketingName(for: "iPhone15,3"), "iPhone 14 Pro Max")
        XCTAssertNil(DeviceModelNames.marketingName(for: "iPhone99,9"))
        var android = registration("r1", tag: "A", entra: "E1", model: "SM-A155F")
        android.deviceManufacturer = "samsung"
        XCTAssertEqual(MAMHostDevice.group(MAMDeviceGroup.group([android])).first?.title, "Samsung SM-A155F")
        let unknown = registration("r2", tag: "B", entra: "E2", model: "iPhone99,9")
        XCTAssertEqual(MAMHostDevice.group(MAMDeviceGroup.group([unknown])).first?.title, "iPhone99,9")
    }

    func testAndroidOSNameComesFromThePackageID() throws {
        let data = Data(#"{"id":"a1","userId":"user-1","deviceType":"SM-A155F","platformVersion":"16","deviceTag":"T","appIdentifier":{"packageId":"com.microsoft.office.outlook"}}"#.utf8)
        var r = try GraphJSON.makeDecoder().decode(MAMRegistration.self, from: data)
        r.azureADDeviceId = "E3"; r.deviceModel = "SM-A155F"; r.deviceManufacturer = "samsung"
        XCTAssertEqual(MAMHostDevice.group(MAMDeviceGroup.group([r])).first?.osDescription, "Android 16")
    }

    // MARK: Plan

    func testPhoneWithTwoTagsPlansTwoRequestsForOneDevice() {
        let groups = MAMDeviceGroup.group([registration("r1", tag: "A", entra: "E1"), registration("r2", tag: "B", entra: "E1")])
        var selection = OffboardingSelection()
        for group in groups { selection.set(.mamSelectiveWipe, for: .mamDeviceGroup(group.id)) }
        let plan = selection.makePlan(user: user, mode: .production, devices: [], mamGroups: groups)

        XCTAssertEqual(plan.selectiveWipeCount, 2)
        XCTAssertEqual(plan.selectiveWipeDeviceCount, 1)
        XCTAssertEqual(Set(plan.actions.map(\.asset)), [.mamDeviceGroup("A"), .mamDeviceGroup("B")])
        XCTAssertTrue(plan.actions.allSatisfy { $0.hostLabel == "iPhone 17 Pro Max, iOS 27.2.1" })
        let policy = ConfirmationPolicy(plan: plan)
        XCTAssertTrue(policy.alertTitle.contains("1 device"))
        XCTAssertTrue(policy.warning.contains("2 requests"))
        XCTAssertEqual(policy.destructiveDeviceLines.count, 2, "every request is listed in the confirmation")
    }
}
