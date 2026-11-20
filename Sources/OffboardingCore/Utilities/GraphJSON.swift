import Foundation

/// Shared JSON decoding configuration for Microsoft Graph responses.
public enum GraphJSON {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unrecognised Graph date: \(string)")
            }
            return date
        }
        return decoder
    }

    /// Graph may return no fraction ("…:43Z"), millis, or 7 digits ("….7971910Z").
    /// ISO8601DateFormatter is only reliable with 0 or 3 fractional digits, so normalise first.
    static func parseDate(_ string: String) -> Date? {
        if let date = withoutFraction.date(from: string) { return date }
        let millis = string.replacingOccurrences(
            of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        if let date = withFraction.date(from: millis) { return date }
        let noFraction = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return withoutFraction.date(from: noFraction)
    }
}
