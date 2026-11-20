import Foundation

/// One line of the local audit trail (JSON Lines). Contains identifiers and outcomes only: no tokens, headers
/// or other credential material ever reach this type, and free text is passed through `LogRedactor` anyway.
public struct AuditRecord: Codable, Equatable, Identifiable, Sendable {
    /// Unique per run and asset. The asset id is part of it because two devices can share a name and the stored
    /// timestamp has whole-second precision.
    public var id: String {
        "\(runId)-\(event.rawValue)-\(managedDeviceId ?? mamRegistrationIds?.joined(separator: ",") ?? assetName ?? "")"
    }
    /// `runStarted` is written before anything is sent, so an interrupted run still leaves a trace;
    /// `operation` is written once per asset when the run ends.
    public enum Event: String, Codable, Sendable { case runStarted, operation }

    public let event: Event
    public let runId: String
    public let timestamp: Date
    public let mode: String                 // "simulation" | "production"
    public let adminUPN: String
    /// Entra object id of the administrator: unlike the UPN claim it does not change when a name does.
    public let adminObjectId: String
    public let tenantId: String
    public let targetUPN: String
    public let targetUserId: String
    public var assetName: String?
    public var serialNumber: String?
    public var managedDeviceId: String?
    public var mamRegistrationIds: [String]?
    public var operation: String?           // e.g. "mdmWipe"
    public var apiOperation: String?
    public var httpStatus: Int?
    public var result: String?              // OperationState raw value
    public var message: String?
}

public protocol AuditRecording: Sendable {
    /// Called before execution. Returns the run id used by the later `recordRun`, or nil when the record could
    /// NOT be written (the caller must then refuse a production run: nothing destructive without an audit trail).
    func recordRunStarted(plan: OffboardingPlan, admin: AdminSession) async -> String?
    func recordRun(runId: String, plan: OffboardingPlan, result: OffboardingResult, admin: AdminSession) async
    /// Folder holding the audit files, for the "Show audit log" button.
    var directory: URL { get }
    /// Most recent records first, newest files first, at most `limit`. Unreadable lines are skipped.
    func recentRecords(limit: Int) async -> [AuditRecord]
}

/// Appends audit records to `<directory>/audit-YYYY-MM.jsonl`. Failure to write is logged but never blocks or
/// alters an offboarding run: the audit trail is a record of what happened, not a gate.
public actor AuditService: AuditRecording {
    public nonisolated let directory: URL
    private let log = AppLogger(category: .audit)
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = e
    }

    /// Reads the audit files in `directory` (newest records first, at most `limit`). Unreadable lines are skipped.
    public static func loadRecords(from directory: URL, limit: Int = 2000) -> [AuditRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("audit-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var records: [AuditRecord] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Within a file records are in write order, so reverse for newest first.
            let parsed = text.split(separator: "\n").compactMap { try? decoder.decode(AuditRecord.self, from: Data($0.utf8)) }
            records.append(contentsOf: parsed.reversed())
            if records.count >= limit { break }
        }
        return Array(records.prefix(limit))
    }

    /// ~/Library/Logs/DeviceOffboarding
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DeviceOffboarding", isDirectory: true)
    }

    public func recordRunStarted(plan: OffboardingPlan, admin: AdminSession) -> String? {
        let runId = UUID().uuidString
        guard append([base(.runStarted, runId, plan, admin, message: "\(plan.actions.count) action(s) selected")]) else { return nil }
        return runId
    }

    public func recordRun(runId: String, plan: OffboardingPlan, result: OffboardingResult, admin: AdminSession) {
        let records = result.operations.map { op -> AuditRecord in
            var r = base(.operation, runId, plan, admin, message: op.message)
            let planned = plan.actions.first { $0.asset == op.asset }
            r.assetName = op.assetLabel
            r.serialNumber = planned?.serialNumber
            switch op.asset {
            case .managedDevice(let id): r.managedDeviceId = id
            case .mamDeviceGroup:
                if case .mamGroup(let ids)? = planned?.fingerprint { r.mamRegistrationIds = ids }
            default: break
            }
            r.operation = op.action.rawValue
            r.apiOperation = op.apiOperation ?? planned?.apiOperation
            r.httpStatus = op.httpStatus
            r.result = op.state.rawValue
            return r
        }
        append(records)
    }

    public func recentRecords(limit: Int = 500) -> [AuditRecord] {
        Self.loadRecords(from: directory, limit: limit)
    }

    private func base(_ event: AuditRecord.Event, _ runId: String, _ plan: OffboardingPlan,
                      _ admin: AdminSession, message: String) -> AuditRecord {
        AuditRecord(event: event, runId: runId, timestamp: now(), mode: plan.mode == .simulation ? "simulation" : "production",
                    adminUPN: admin.username, adminObjectId: admin.accountId, tenantId: admin.tenantId, targetUPN: plan.user.userPrincipalName,
                    targetUserId: plan.user.id, message: LogRedactor.redact(message))
    }

    @discardableResult
    private func append(_ records: [AuditRecord]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            let file = directory.appendingPathComponent("audit-\(fmt.string(from: now())).jsonl")
            var data = Data()
            for record in records { data.append(try encoder.encode(record)); data.append(0x0A) }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            log.error("Could not write the audit log: \(error.localizedDescription)")
            return false
        }
    }
}
