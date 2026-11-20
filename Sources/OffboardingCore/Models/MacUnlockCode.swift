import Foundation

/// The six-digit recovery PIN sent with a Mac wipe, as the Intune portal does. Needed to unlock older Macs (no T2
/// chip) after the erase; Intune also shows it on the device page until the wipe completes. Never logged or audited.
public enum MacUnlockCode {
    /// Six random digits from the system's cryptographically secure generator.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    public static func isValid(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

extension ManagedDevice {
    /// Graph reports "macOS" for Macs. Decides only whether a wipe carries the Mac unlock PIN.
    public var isMacOS: Bool { operatingSystem?.lowercased() == "macos" }
}
