import AppKit
import OffboardingCore
import SwiftUI

/// Read-only viewer for the local audit trail (the newest 500 records).
struct AuditLogView: View {
    @EnvironmentObject private var viewModel: OffboardingViewModel
    @State private var records: [AuditRecord] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Audit log").font(.title2).fontWeight(.bold)
                Spacer()
                Button("Refresh") { Task { await load() } }
                if let folder = viewModel.auditDirectory {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                }
            }
            if viewModel.auditDirectory == nil {
                Text("Auditing is not configured in this build.").foregroundStyle(.secondary)
            } else if records.isEmpty {
                Text(loading ? "Loading…" : "No audit records yet. Every simulation and production run is recorded here.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(records) { record in
                            AuditRow(record: record)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        loading = true
        records = await viewModel.loadAuditRecords()
        loading = false
    }
}

private struct AuditRow: View {
    let record: AuditRecord

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    Text(record.mode.uppercased())
                        .font(.caption2).fontWeight(.bold)
                        .foregroundStyle(record.mode == "production" ? Color.red : Color.orange)
                    Spacer()
                    if let result = record.result {
                        Text(result).font(.caption).fontWeight(.semibold)
                    }
                    if let status = record.httpStatus {
                        Text("HTTP \(status)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if record.event == .runStarted {
                    Text("Run started for \(record.targetUPN)").fontWeight(.semibold)
                } else {
                    Text("\(record.assetName ?? "—") · \(record.operation ?? "—")").fontWeight(.semibold)
                    Text("Target \(record.targetUPN)").font(.caption).foregroundStyle(.secondary)
                }
                Text("Admin \(record.adminUPN) · tenant \(record.tenantId)").font(.caption).foregroundStyle(.secondary)
                if let api = record.apiOperation {
                    Text(api).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let message = record.message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
