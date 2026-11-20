import Foundation

/// Device details of an app-protection registration that Graph v1.0 does not expose.
public struct MAMRegistrationDeviceDetails: Decodable, Equatable, Sendable {
    public let id: String
    public let azureADDeviceId: String?
    public let deviceModel: String?
    public let deviceManufacturer: String?

    public init(id: String, azureADDeviceId: String?, deviceModel: String?, deviceManufacturer: String?) {
        self.id = id
        self.azureADDeviceId = azureADDeviceId
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
    }
}

public protocol MAMDeviceDetailsProviding: Sendable {
    func deviceDetails(forUserID userID: String) async throws -> [MAMRegistrationDeviceDetails]
}

/// BETA, isolated on purpose. `azureADDeviceId`, `deviceModel` and `deviceManufacturer` exist only on the beta
/// `managedAppRegistration` (checked November 2026; v1.0 has `deviceName`, `deviceType` and `platformVersion`).
///
/// GET /beta/users/{id}/managedAppRegistrations (delegated DeviceManagementApps.Read.All, same as v1.0).
///
/// Read-only and optional: the results only label registrations and show them per phone. Which registrations
/// exist, which belong to the user, and what a selective wipe targets all come from v1.0. If this call fails or
/// the beta API changes, the app falls back to one entry per device tag. To drop beta, delete this file and
/// pass no details provider to `MAMService`.
public struct BetaMAMDeviceDetailsService: MAMDeviceDetailsProviding {
    private let graph: GraphClient

    /// `graph` must be a client created with `baseURL: GraphClient.betaBase`.
    public init(graph: GraphClient) { self.graph = graph }

    public func deviceDetails(forUserID userID: String) async throws -> [MAMRegistrationDeviceDetails] {
        guard GraphID.isSafe(userID) else { throw MAMDiscoveryError.invalidUserID }
        // No $select: the collection is polymorphic and the default projection already includes these fields.
        return try await graph.getAll("/users/\(userID)/managedAppRegistrations")
    }
}
