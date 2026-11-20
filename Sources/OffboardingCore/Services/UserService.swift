import Foundation

public protocol UserResolving: Sendable {
    func resolve(upn: String) async throws -> EntraUser
}

public enum UserLookupError: Error, Equatable, LocalizedError, Sendable {
    case invalidUPN
    case notFound(String)
    case ambiguous(Int)
    case mismatch

    public var errorDescription: String? {
        switch self {
        case .invalidUPN:
            return "That is not a valid UPN. Enter the full user principal name, for example john.doe@company.com."
        case .notFound(let upn):
            return "No user with the UPN \(upn) exists in this tenant. Check the spelling; the search is exact."
        case .ambiguous(let count):
            return "Unexpected result: \(count) users matched this UPN. Stopping so nothing is done to the wrong identity."
        case .mismatch:
            return "The directory returned a different identity than the one requested. Stopping for safety."
        }
    }
}

/// Resolves a UPN to exactly one Entra user. There is deliberately no fuzzy or partial matching:
/// destructive actions must never run against a "close enough" identity.
///
/// Uses GET /v1.0/users?$filter=userPrincipalName eq '…' (delegated User.ReadBasic.All is enough
/// for the list call; confirm on a first run that the UPN filter works with this permission).
public struct UserService: UserResolving {
    private let graph: GraphClient
    private let log = AppLogger(category: .workflow)

    public init(graph: GraphClient) { self.graph = graph }

    public func resolve(upn rawInput: String) async throws -> EntraUser {
        let upn = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidUPN(upn) else { throw UserLookupError.invalidUPN }

        // OData string literal: a single quote is escaped by doubling it.
        let escaped = upn.replacingOccurrences(of: "'", with: "''")
        let users: [EntraUser] = try await graph.getAll("/users", query: [
            ("$filter", "userPrincipalName eq '\(escaped)'"),
            ("$select", EntraUser.graphSelect.joined(separator: ",")),
        ])

        switch users.count {
        case 0: throw UserLookupError.notFound(upn)
        case 1: break
        default: throw UserLookupError.ambiguous(users.count)
        }
        let user = users[0]
        guard user.userPrincipalName.caseInsensitiveCompare(upn) == .orderedSame else {
            throw UserLookupError.mismatch
        }
        log.info("Resolved UPN to Entra user \(user.id)")
        return user
    }

    static func isValidUPN(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
