import Foundation
#if canImport(os)
import os
#endif

public enum LogLevel: Int, Sendable, Comparable {
    case debug, info, notice, warning, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LogCategory: String, Sendable {
    case app, auth, graph, workflow, audit, ui
}

/// Application logger. Messages are redacted BEFORE reaching the sink, so tokens, auth headers
/// and secrets cannot be written by accident. Default sink is unified logging (Console.app,
/// subsystem "IntuneOffboarding"); tests inject their own sink.
///
/// This is diagnostic logging only. The per-operation audit trail is a separate type (Phase 11).
public struct AppLogger: Sendable {
    public typealias Sink = @Sendable (LogLevel, LogCategory, String) -> Void

    public static let subsystem = "IntuneOffboarding"

    private let category: LogCategory
    private let sink: Sink

    public init(category: LogCategory, sink: Sink? = nil) {
        self.category = category
        self.sink = sink ?? AppLogger.defaultSink
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        sink(level, category, LogRedactor.redact(message()))
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    private static let defaultSink: Sink = { level, category, message in
        #if canImport(os)
        let logger = Logger(subsystem: AppLogger.subsystem, category: category.rawValue)
        // Already redacted, so .public keeps messages readable in Console.app.
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        #else
        FileHandle.standardError.write(Data("[\(category.rawValue)] \(message)\n".utf8))
        #endif
    }
}
