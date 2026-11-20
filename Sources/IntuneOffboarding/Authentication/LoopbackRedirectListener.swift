import Foundation
import Network
import OffboardingCore

/// Receives the OAuth redirect on `http://localhost:<random port>` (the loopback redirect for native apps,
/// RFC 8252 §7.3) and hands back the authorization code.
///
/// - Listens on the loopback interface only, so nothing outside this Mac can reach it.
/// - One sign-in per instance. Requests without the expected `state` are answered and ignored, so a
///   stray request (favicon, another local program) can neither complete nor break the sign-in.
/// - The page it serves never echoes anything from the request.
final class LoopbackRedirectListener: @unchecked Sendable {
    struct Result {
        let code: String
        let port: UInt16
    }

    private let queue = DispatchQueue(label: "com.example.deviceoffboarding.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Result, Error>?
    private var expectedState = ""
    private var port: UInt16 = 0
    private var finished = false

    /// Starts listening and calls `onReady` with the port once it is bound (the caller opens the browser
    /// there), then waits for the redirect. Cancelling the calling task, or the timeout, ends it.
    func receiveCode(
        expectedState: String, timeout: TimeInterval, onReady: @escaping @Sendable (UInt16) -> Void
    ) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(continuation, expectedState: expectedState, timeout: timeout, onReady: onReady) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(AuthError.cancelled)) }
        }
    }

    // MARK: - Queue-confined state

    private func begin(
        _ continuation: CheckedContinuation<Result, Error>, expectedState: String, timeout: TimeInterval,
        onReady: @escaping @Sendable (UInt16) -> Void
    ) {
        if finished { continuation.resume(throwing: AuthError.cancelled); return }
        self.continuation = continuation
        self.expectedState = expectedState

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        return self.finish(.failure(AuthError.oauthFailure("Could not open a local port for the sign-in redirect.")))
                    }
                    self.port = port
                    onReady(port)
                case .failed(let error):
                    self.finish(.failure(AuthError.oauthFailure("The local sign-in listener failed: \(error.localizedDescription)")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        } catch {
            finish(.failure(AuthError.oauthFailure("Could not start the local sign-in listener: \(error.localizedDescription)")))
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(AuthError.oauthFailure("Sign-in timed out. Start again and finish it in the browser.")))
        }
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let outcome = self.interpret(data)
            self.reply(on: connection, outcome: outcome)
            if case .complete(let result) = outcome { self.finish(result) }
        }
    }

    private enum Outcome {
        case ignore
        case reject
        case complete(Swift.Result<Result, Error>)
    }

    /// Parses `GET /?code=…&state=…` (or `?error=…&state=…`) from the first request line.
    private func interpret(_ data: Data?) -> Outcome {
        guard let data, let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return .reject }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost" + parts[1]) else { return .reject }
        guard components.path == "/" else { return .ignore } // /favicon.ico and friends
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        guard items["state"] == expectedState else { return .reject } // wrong or missing state: not ours

        if let error = items["error"] {
            let description = items["error_description"]?.split(whereSeparator: \.isNewline).first.map(String.init)
            return .complete(.failure(error == "access_denied" && description == nil
                ? AuthError.cancelled
                : AuthError.oauthFailure([error, description].compactMap { $0 }.joined(separator: ": "))))
        }
        guard let code = items["code"], !code.isEmpty else { return .reject }
        return .complete(.success(Result(code: code, port: port)))
    }

    private func reply(on connection: NWConnection, outcome: Outcome) {
        let status: String, body: String
        switch outcome {
        case .complete(.success):
            (status, body) = ("200 OK", "Sign-in complete. You can close this tab and return to Device Offboarding.")
        case .complete(.failure):
            (status, body) = ("200 OK", "Sign-in did not complete. Return to Device Offboarding for details.")
        case .ignore:
            (status, body) = ("404 Not Found", "Not found.")
        case .reject:
            (status, body) = ("400 Bad Request", "Invalid request.")
        }
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Device Offboarding</title></head>"
            + "<body style=\"font-family:-apple-system,sans-serif;margin:3em\"><p>\(body)</p></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
