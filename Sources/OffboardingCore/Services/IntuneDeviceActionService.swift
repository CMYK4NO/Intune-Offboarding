import Foundation

public enum DeviceActionError: Error, Equatable, LocalizedError, Sendable {
    case invalidDeviceID
    case invalidUnlockCode

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceID: return "The device has an unexpected ID format. Nothing was sent."
        case .invalidUnlockCode: return "The Mac unlock PIN must be exactly six digits. Nothing was sent."
        }
    }
}

/// The write side of device offboarding. Kept separate from `DeviceDiscovering` (read-only) so
/// that a discovery-only component can never be handed a wipe capability.
public protocol DeviceActionPerforming: Sendable {
    /// Reads one device by its Intune id (used to re-verify right before a destructive action).
    func currentDevice(id: String) async throws -> ManagedDevice
    /// Submits an MDM Wipe. Returns the HTTP status (204 = accepted, NOT completed). `options` are the Windows-only
    /// "keep" switches; `.fullWipe` for everything else.
    func wipe(deviceID: String, options: WipeOptions, macOsUnlockCode: String?) async throws -> Int
    /// Submits a Retire (`POST /deviceManagement/managedDevices/{id}/retire`, no body). Returns the HTTP status (204 =
    /// accepted; company data and management are removed when the device next checks in). Separate from wipe and delete.
    func retire(deviceID: String) async throws -> Int
    /// Deletes the managed-device RECORD in Intune (`DELETE /deviceManagement/managedDevices/{id}`). Returns the HTTP
    /// status (204). This is a separate operation from `wipe` and is never issued as part of one.
    func deleteRecord(deviceID: String) async throws -> Int
}

/// Body of `POST /deviceManagement/managedDevices/{id}/wipe` (Graph v1.0).
///
/// Always sent explicitly: Graph treats a missing body as all-false, and relying on that default
/// would hide what the app actually asks for. The default (`.fullWipe`) means: erase everything, remove the MDM
/// enrolment, do not keep user data, do not keep an eSIM data plan.
/// `keepEnrollmentData` and `keepUserData` are the Windows-only switches (Graph: doWipePersistProvisionedData and
/// doWipePersistUserData); they are true only when the administrator chose them for a Windows device.
/// `macOsUnlockCode` is not sent (documented as a String without further description). `useProtectedWipe` and
/// `obliterationBehavior` exist only in /beta and are deliberately not used.
struct WipeRequestBody: Encodable {
    let keepEnrollmentData: Bool
    let keepUserData: Bool
    /// Six-digit recovery PIN, sent for Macs only (Graph v1.0: "A six-digit recovery PIN used when remotely wiping a
    /// Mac via MDM"). The Intune portal sends one for every Mac wipe; without it Intune accepted the request (204) but
    /// marked it wipeFailed and never sent EraseDevice. Omitted from the JSON when nil.
    let macOsUnlockCode: String?
    let persistEsimDataPlan = false

    init(_ options: WipeOptions = .fullWipe, macOsUnlockCode: String? = nil) {
        keepEnrollmentData = options.keepEnrollmentData
        keepUserData = options.keepUserData
        self.macOsUnlockCode = macOsUnlockCode
    }
}

/// v1.0 operations (wipe: delegated PrivilegedOperations.All; delete: delegated ReadWrite.All; retire: the app already
/// requests both of those scopes, so whichever of them the retire page lists is covered):
/// - GET  /deviceManagement/managedDevices/{id}
/// - POST /deviceManagement/managedDevices/{id}/wipe → 204 No Content
/// - POST /deviceManagement/managedDevices/{id}/retire → 204 No Content, no request body
/// - DELETE /deviceManagement/managedDevices/{id}     → 204 No Content, no request body
public struct IntuneDeviceActionService: DeviceActionPerforming {
    private let graph: GraphClient
    private let log = AppLogger(category: .workflow)

    public init(graph: GraphClient) { self.graph = graph }

    public func currentDevice(id: String) async throws -> ManagedDevice {
        guard Self.isPathSafe(id) else { throw DeviceActionError.invalidDeviceID }
        return try await graph.get(
            "/deviceManagement/managedDevices/\(id)",
            query: [("$select", ManagedDevice.graphSelect.joined(separator: ","))])
    }

    public func wipe(deviceID: String, options: WipeOptions, macOsUnlockCode: String? = nil) async throws -> Int {
        guard Self.isPathSafe(deviceID) else { throw DeviceActionError.invalidDeviceID }
        log.info("Submitting MDM wipe for managed device \(deviceID)\(options.isFullWipe ? "" : " (\(options.summary))")")
        if let macOsUnlockCode, !MacUnlockCode.isValid(macOsUnlockCode) { throw DeviceActionError.invalidUnlockCode }
        // The PIN itself is never logged.
        return try await graph.post(
            "/deviceManagement/managedDevices/\(deviceID)/wipe",
            body: WipeRequestBody(options, macOsUnlockCode: macOsUnlockCode))
    }

    public func retire(deviceID: String) async throws -> Int {
        guard Self.isPathSafe(deviceID) else { throw DeviceActionError.invalidDeviceID }
        log.info("Submitting retire for managed device \(deviceID)")
        return try await graph.post("/deviceManagement/managedDevices/\(deviceID)/retire")
    }

    public func deleteRecord(deviceID: String) async throws -> Int {
        guard Self.isPathSafe(deviceID) else { throw DeviceActionError.invalidDeviceID }
        log.info("Submitting delete of Intune record for managed device \(deviceID)")
        return try await graph.delete("/deviceManagement/managedDevices/\(deviceID)")
    }

    /// The id is placed in a URL path, so only GUID-like characters are accepted.
    static func isPathSafe(_ id: String) -> Bool {
        GraphID.isSafe(id)
    }
}
