import Foundation

/// Strips credential material from text before it reaches any log.
/// Every message passes through here in `AppLogger`; callers should still avoid
/// passing tokens/headers at all.
public enum LogRedactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Authorization header/value, with or without the Bearer scheme.
            (#"(?i)(authorization\s*[:=]\s*)(bearer\s+)?[^\s,;"']+"#, "$1[REDACTED]"),
            // Loose "Bearer <token>".
            (#"(?i)\bbearer\s+[A-Za-z0-9\-._~+/]+=*"#, "Bearer [REDACTED]"),
            // JWTs (access/id tokens).
            (#"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#, "[REDACTED_JWT]"),
            // OAuth fields in JSON, form bodies or query strings. A bare "code" key is NOT
            // matched: Graph error JSON uses "code" for error names (e.g. "Forbidden").
            (#"(?i)("?(?:access_token|refresh_token|id_token|client_secret|client_assertion|code_verifier|password)"?\s*[:=]\s*"?)[^"&\s,}]+"#, "$1[REDACTED]"),
            // Authorization code in a redirect URL.
            (#"(?i)([?&]code=)[^&\s]+"#, "$1[REDACTED]"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
