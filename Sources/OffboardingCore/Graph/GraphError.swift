import Foundation

/// Structured Graph failure, phrased for an endpoint administrator.
public enum GraphError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized(detail: String?)
    case forbidden(detail: String?)
    case notFound(detail: String?)
    case conflict(detail: String?)
    case throttled(retryAfter: TimeInterval?)
    case server(status: Int, detail: String?)
    case http(status: Int, detail: String?)
    case network(String)
    case decoding(String)
    case invalidResponse
    case untrustedPagingLink(String)
    /// A list kept returning more pages than any real result has (or the same page again); stopped.
    case tooManyPages
    /// Destructive request sent but the reply was lost (or Graph answered 5xx), so the operation
    /// may or may not have happened. Never retried automatically.
    case outcomeUnknown(String)

    /// HTTP status behind the error, when there is one.
    public var httpStatus: Int? {
        switch self {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .throttled: return 429
        case .server(let status, _), .http(let status, _): return status
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Microsoft Graph rejected the sign-in (401). Your session may have expired; sign in again."
        case .forbidden:
            return "Your account authenticated successfully but does not have permission to perform this operation (403). Check admin consent for the app's Graph permissions and your Intune/Entra role."
        case .notFound:
            return "The requested object was not found (404)."
        case .conflict:
            return "The request conflicts with the current state of the object (409)."
        case .throttled(let retryAfter):
            let hint = retryAfter.map { " Try again in about \(Int($0)) seconds." } ?? ""
            return "Microsoft Graph is throttling requests (429).\(hint)"
        case .server(let status, _):
            return "Microsoft Graph had a server problem (\(status)). Try again shortly."
        case .http(412, _):
            // Intune Multi Admin Approval answers 412 when an action needs a second administrator's approval.
            return "HTTP 412: this action probably needs Multi Admin Approval in your tenant, which this app does not support "
                + "yet. It was not carried out by the app. Check Tenant administration > Multi Admin Approval in Intune."
        case .http(let status, let detail):
            return "Microsoft Graph returned HTTP \(status)\(detail.map { ": \($0)" } ?? "")."
        case .network(let detail):
            return "Network problem while contacting Microsoft Graph: \(detail)"
        case .decoding(let detail):
            return "Could not read the response from Microsoft Graph: \(detail)"
        case .invalidResponse:
            return "Microsoft Graph returned an unexpected response."
        case .untrustedPagingLink:
            return "Microsoft Graph returned a paging link to an unexpected host; the request was stopped."
        case .tooManyPages:
            return "Microsoft Graph kept returning more pages than expected; the list was stopped. Try again later."
        case .outcomeUnknown(let detail):
            return "The request was sent but its outcome is unknown (\(detail)). Verify the object's state before retrying."
        }
    }
}

/// Graph error body: {"error":{"code":"…","message":"…"}}
struct GraphErrorBody: Decodable {
    struct Inner: Decodable { let code: String?; let message: String? }
    let error: Inner?

    var summary: String? {
        guard let error else { return nil }
        return [error.code, error.message].compactMap { $0 }.joined(separator: " – ")
    }
}
