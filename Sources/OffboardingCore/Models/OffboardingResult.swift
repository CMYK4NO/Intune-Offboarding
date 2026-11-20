import Foundation

/// Independent state of one operation. A failure on one asset never changes another's state.
public enum OperationState: String, Codable, Sendable {
    case pending
    case validating
    case executing
    /// Request accepted by Graph (e.g. 204). NOT proof the physical wipe has completed.
    case submitted
    /// Outcome confirmed (e.g. verified by reading device state).
    case succeeded
    case failed
    /// Timeout/network loss after sending a destructive request: may or may not have happened.
    /// Never auto-retry; the admin must verify.
    case outcomeUnknown
    case skipped

    /// No further automatic transitions are expected.
    public var isFinal: Bool {
        switch self {
        case .pending, .validating, .executing: return false
        default: return true
        }
    }
}

public struct OperationResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let asset: AssetID
    /// Display only (device name etc.); identity is `asset`.
    public let assetLabel: String
    public let action: OffboardingAction
    public var state: OperationState
    public var httpStatus: Int?
    public var message: String
    public var timestamp: Date
    /// The Graph operation this action maps to, for the audit trail and the simulation preview.
    public var apiOperation: String?
    /// Mac wipes only: the six-digit unlock PIN that was sent. Shown on the results screen; deliberately NOT copied
    /// into the message, the audit trail or any log.
    public var macOsUnlockCode: String?
    /// Wipe and retire only: what Intune showed for the action a few seconds after the request was accepted.
    public var intuneRegistration: IntuneRegistration?

    public init(
        id: UUID = UUID(), asset: AssetID, assetLabel: String, action: OffboardingAction,
        state: OperationState = .pending, httpStatus: Int? = nil, message: String = "",
        timestamp: Date = Date(), apiOperation: String? = nil
    ) {
        self.apiOperation = apiOperation
        self.id = id
        self.asset = asset
        self.assetLabel = assetLabel
        self.action = action
        self.state = state
        self.httpStatus = httpStatus
        self.message = message
        self.timestamp = timestamp
    }
}

public struct OffboardingResult: Sendable {
    public let mode: ExecutionMode
    public var operations: [OperationResult]

    public init(mode: ExecutionMode, operations: [OperationResult] = []) {
        self.mode = mode
        self.operations = operations
    }

    public enum Summary: Equatable, Sendable {
        case nothingToDo
        case inProgress
        case completed
        case completedWithWarnings
        case failed
        /// Simulation finished: nothing was sent to Graph.
        case simulated
        /// Production run in which every selected action was skipped (not supported yet).
        case notExecuted
    }

    /// Partial success is a first-class outcome, not an error.
    public var summary: Summary {
        let ops = operations.filter { $0.action.isDestructive }
        guard !ops.isEmpty else { return .nothingToDo }
        guard ops.allSatisfy({ $0.state.isFinal }) else { return .inProgress }
        let hasProblem = ops.contains { $0.state == .failed || $0.state == .outcomeUnknown }
        let hasSuccess = ops.contains { $0.state == .submitted || $0.state == .succeeded }
        // In production a skipped destructive action means something the admin chose did not happen.
        let hasSkipped = mode == .production && ops.contains { $0.state == .skipped }
        switch (hasProblem || hasSkipped, hasSuccess) {
        case (false, _): return mode == .simulation ? .simulated : .completed
        case (true, true): return .completedWithWarnings
        case (true, false): return hasProblem ? .failed : .notExecuted
        }
    }
}
