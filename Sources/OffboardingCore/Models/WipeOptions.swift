import Foundation

/// The Windows-only switches of the Intune wipe action: `keepEnrollmentData` and `keepUserData` in the Graph v1.0
/// wipe body. Microsoft documents them as "Uses doWipePersistProvisionedData" and "Uses doWipePersistUserData".
///
/// Both default to false, which is a full wipe. Offboarding normally wants the full wipe, so keeping anything is an
/// explicit per-device choice: it is shown in the review, in the confirmation and in the audit log. The options are
/// ignored for every device that is not Windows.
public struct WipeOptions: Hashable, Codable, Sendable {
    public var keepEnrollmentData: Bool
    public var keepUserData: Bool

    public init(keepEnrollmentData: Bool = false, keepUserData: Bool = false) {
        self.keepEnrollmentData = keepEnrollmentData
        self.keepUserData = keepUserData
    }

    public static let fullWipe = WipeOptions()

    public var isFullWipe: Bool { !keepEnrollmentData && !keepUserData }

    /// Short text for the review, the confirmation and the audit log. Empty for a full wipe.
    public var summary: String {
        var parts: [String] = []
        if keepEnrollmentData { parts.append("KEEPS enrollment data") }
        if keepUserData { parts.append("KEEPS user data") }
        return parts.joined(separator: ", ")
    }
}
