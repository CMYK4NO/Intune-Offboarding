import Foundation

/// Runs a validated plan and reports each operation's own state as it changes.
public protocol OffboardingExecuting: Sendable {
    func execute(
        _ plan: OffboardingPlan,
        onUpdate: @escaping @Sendable (OperationResult) async -> Void
    ) async -> OffboardingResult
}

/// Dry run. It is given NO Graph client, so it cannot send a POST or DELETE: "no changes were made"
/// is guaranteed by construction, not by an if-statement.
public struct SimulationExecutor: OffboardingExecuting {
    private let log = AppLogger(category: .workflow)

    public init() {}

    public func execute(
        _ plan: OffboardingPlan,
        onUpdate: @escaping @Sendable (OperationResult) async -> Void
    ) async -> OffboardingResult {
        var operations = plan.actions.map {
            OperationResult(asset: $0.asset, assetLabel: $0.label, action: $0.action, apiOperation: $0.apiOperation)
        }
        for index in operations.indices {
            for state in [OperationState.validating, .executing] {
                operations[index].state = state
                operations[index].timestamp = Date()
                await onUpdate(operations[index])
            }
            // Nothing was sent, so the final state is `skipped`, never `submitted` or `succeeded`.
            operations[index].state = .skipped
            operations[index].message = "SIMULATION: would execute \(operations[index].action.title). No changes were made."
            operations[index].timestamp = Date()
            await onUpdate(operations[index])
            log.info("Simulated \(operations[index].action.rawValue) for asset \(operations[index].asset.rawID)")
        }
        return OffboardingResult(mode: .simulation, operations: operations)
    }
}
