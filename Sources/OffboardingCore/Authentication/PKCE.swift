import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Base64 without padding, URL-safe alphabet (RFC 4648 §5), as used by PKCE and JWTs.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}

/// Unguessable values from the system's cryptographically secure generator.
public enum SecureRandom {
    /// 32 bytes by default, i.e. 43 URL-safe characters.
    public static func token(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(Data(bytes))
    }
}

/// Proof Key for Code Exchange (RFC 7636), S256 method. The verifier never leaves the app until
/// the code is exchanged; only its SHA-256 challenge goes to the browser. This is what replaces a
/// client secret in a native public client.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(Self.sha256(Data(verifier.utf8)))
    }

    public static func generate() -> PKCE {
        PKCE(verifier: SecureRandom.token(byteCount: 32))
    }

    private static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        fatalError("CryptoKit is required on this platform")
        #endif
    }
}
