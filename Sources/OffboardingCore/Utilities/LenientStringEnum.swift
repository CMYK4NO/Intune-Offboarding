import Foundation

/// Graph enums gain new members over time. A strict `Codable` enum would fail the
/// whole device list on one unknown value, so these decode unknown strings to `fallback`.
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable where RawValue == String {
    static var fallback: Self { get }
}

public extension LenientStringEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
