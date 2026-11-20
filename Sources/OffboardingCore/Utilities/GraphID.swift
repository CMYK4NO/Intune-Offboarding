import Foundation

/// Ids (managed device, user) are placed into URL paths, so only GUID-like values are accepted.
/// A character-set check on purpose: a regex `$` also matches before a trailing newline, so
/// "abc\n" would have passed `^[A-Za-z0-9\-]+$`.
public enum GraphID {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")

    public static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
