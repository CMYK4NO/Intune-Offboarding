import Foundation

/// Runs a confirmed plan against Microsoft Graph.
///
/// Supports MDM Wipe (Phase 8), Retire, Delete from Intune (Phase 9) and MAM Selective Wipe (Phase 10). Without a
/// `MAMActionPerforming` a selective wipe is reported as `skipped`, never silently dropped and never run.
/// Wipe, Retire, Delete and Selective Wipe are separate operations: nothing here issues one as a
/// consequence of another.
///
/// Safety rules, in order, for every device operation:
///  0. A plan over the per-run limit, or listing an asset twice, is refused: nothing is sent.
///  1. The administrator's session is re-verified once before the first destructive call.
///  2. The device (or, for a selective wipe, the user's registrations on that device) is re-read and compared with
///     what was reviewed: same user, serial number and name, or the same set of registration ids. Any difference
///     means nothing is sent for that asset.
///  3. ONE request. No retry. A lost reply is `outcomeUnknown`.
///  4. Wipe and selective wipe: a 204 is `submitted` ("request accepted"), never `succeeded`: it does not prove the
///     physical device has been erased.
///     Delete: after a success status (or an unknown outcome) the record is read once more;
///     404 proves it is gone (`succeeded`). That read is a check, not a retry of the delete.
/// Operations run one after another and are independent: a failure marks only its own asset.
public struct ProductionExecutor: OffboardingExecuting {
    private let actions: DeviceActionPerforming
    private let mam: MAMActionPerforming?
    private let auth: AuthVerifying
    private let scopes: [String]
    /// Wait before reading devices back to confirm Intune registered each wipe or retire (0 in tests).
    private let verificationDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log = AppLogger(category: .workflow)

    public init(
        actions: DeviceActionPerforming, mam: MAMActionPerforming? = nil,
        auth: AuthVerifying, scopes: [String], verificationDelay: TimeInterval = 0,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }
    ) {
        self.mam = mam
        self.actions = actions
        self.auth = auth
        self.scopes = scopes
        self.verificationDelay = verificationDelay
        self.sleep = sleep
    }

    public func execute(
        _ plan: OffboardingPlan,
        onUpdate: @escaping @Sendable (OperationResult) async -> Void
    ) async -> OffboardingResult {
        var operations = plan.actions.map {
            OperationResult(asset: $0.asset, assetLabel: $0.label, action: $0.action, apiOperation: $0.apiOperation)
        }

        // 0. Refuse an oversized or inconsistent plan outright: nothing is sent.
        if let violation = plan.safetyViolation {
            for index in operations.indices {
                operations[index].state = .failed
                operations[index].message = "Not sent: \(violation)"
                operations[index].timestamp = Date()
                await onUpdate(operations[index])
            }
            return OffboardingResult(mode: .production, operations: operations)
        }

        // 1. Session check. If it fails nothing has been sent, so every device operation is a plain failure.
        var sessionError: String?
        if plan.actions.contains(where: { $0.action != .noAction }) {
            do { _ = try await auth.verifyStillAuthenticated(scopes: scopes) }
            catch { sessionError = error.localizedDescription }
        }

        var sentAt: [Int: Date] = [:]
        for index in operations.indices {
            let planned = plan.actions[index]
            switch planned.action {
            case .mdmWipe, .retireDevice, .deleteIntuneRecord:
                if Task.isCancelled {
                    operations[index].state = .skipped
                    operations[index].message = "Not sent: the run was cancelled (for example the sign-in ended)."
                } else if let sessionError {
                    operations[index].state = .failed
                    operations[index].message = "Not sent: your sign-in is no longer valid. \(sessionError)"
                } else {
                    sentAt[index] = Date()
                    await perform(planned, plan: plan, into: &operations[index], onUpdate: onUpdate)
                }
            case .mamSelectiveWipe:
                if mam == nil {
                    operations[index].state = .skipped
                    operations[index].message = "Not executed: MAM Selective Wipe is not available in this build."
                } else if Task.isCancelled {
                    operations[index].state = .skipped
                    operations[index].message = "Not sent: the run was cancelled (for example the sign-in ended)."
                } else if let sessionError {
                    operations[index].state = .failed
                    operations[index].message = "Not sent: your sign-in is no longer valid. \(sessionError)"
                } else {
                    await performSelectiveWipe(planned, plan: plan, into: &operations[index], onUpdate: onUpdate)
                }
            case .noAction:
                operations[index].state = .skipped
                operations[index].message = "No action selected."
            }
            operations[index].timestamp = Date()
            await onUpdate(operations[index])
        }
        await confirmRegistration(of: &operations, sentAt: sentAt, onUpdate: onUpdate)
        return OffboardingResult(mode: .production, operations: operations)
    }

    /// 5. After every request has been sent: wait once, then read each wiped or retired device back and check that
    ///    Intune created a new action entry for it. Read-only; never resends anything. The state stays `submitted`
    ///    (Graph did accept the request); the outcome is added to the message and to `intuneRegistration`.
    private func confirmRegistration(
        of operations: inout [OperationResult], sentAt: [Int: Date],
        onUpdate: @Sendable (OperationResult) async -> Void
    ) async {
        let toCheck = operations.indices.filter {
            [OffboardingAction.mdmWipe, .retireDevice].contains(operations[$0].action) && operations[$0].state == .submitted
        }
        guard !toCheck.isEmpty, !Task.isCancelled else { return }
        let original = Dictionary(uniqueKeysWithValues: toCheck.map { ($0, operations[$0].message) })
        for index in toCheck {
            operations[index].message += " Checking with Intune in a few seconds…"
            await onUpdate(operations[index])
        }
        try? await sleep(verificationDelay)
        for index in toCheck {
            operations[index].message = original[index] ?? operations[index].message
            guard !Task.isCancelled, case .managedDevice(let id) = operations[index].asset else {
                await onUpdate(operations[index])
                continue
            }
            let outcome: (IntuneRegistration, String)
            do {
                let device = try await actions.currentDevice(id: id)
                outcome = device.registration(of: operations[index].action, sentAt: sentAt[index] ?? Date())
            } catch GraphError.notFound {
                outcome = (.recordRemoved, "Intune has already removed this device record, which usually means the "
                    + "\(operations[index].action == .retireDevice ? "retire" : "wipe") completed. Check Intune to be sure.")
            } catch {
                outcome = (.unverified, "Could not read the device back to confirm Intune registered it "
                    + "(\((error as? GraphError)?.localizedDescription ?? error.localizedDescription)). Check it in Intune.")
            }
            operations[index].intuneRegistration = outcome.0
            if !outcome.1.isEmpty { operations[index].message += " " + outcome.1 }
            log.info("Intune registration check for managed device \(id): \(outcome.0.rawValue)")
            await onUpdate(operations[index])
        }
    }

    private func perform(
        _ planned: PlannedAction, plan: OffboardingPlan, into operation: inout OperationResult,
        onUpdate: @Sendable (OperationResult) async -> Void
    ) async {
        let verb: String
        switch planned.action {
        case .mdmWipe: verb = "wiping"
        case .retireDevice: verb = "retiring"
        default: verb = "deleting"
        }
        guard case .managedDevice(let deviceID) = planned.asset else {
            operation.state = .failed
            operation.message = "Internal error: a device operation was requested for a non-device asset. Nothing was sent."
            return
        }

        // 2. Re-verify right before sending. Also decides whether a wipe carries the Mac unlock PIN.
        var isMac = false
        operation.state = .validating
        await onUpdate(operation)
        do {
            let device = try await actions.currentDevice(id: deviceID)
            isMac = device.isMacOS
            guard device.id == deviceID else {
                return fail(&operation, "Intune returned a different device than requested. Nothing was sent.")
            }
            guard device.userId?.caseInsensitiveCompare(plan.user.id) == .orderedSame else {
                return fail(&operation, "The device is no longer associated with \(plan.user.userPrincipalName). Nothing was sent.")
            }
            let now = PlannedAction.Fingerprint.device(
                userId: device.userId, serialNumber: device.serialNumber, deviceName: device.deviceName)
            guard now == planned.fingerprint else {
                return fail(&operation, "The device's name or serial number changed since review. Nothing was sent.")
            }
            // Never stack a new action on one Intune has not finished (repeat wipes, or a delete that drops a wipe).
            if let reason = device.blockingReason(for: planned.action) {
                return fail(&operation, "\(reason) Nothing was sent.")
            }
            // The "keep" switches are Windows-only: never send them for anything else.
            guard planned.wipeOptions.isFullWipe || device.isWindows else {
                return fail(&operation, "The wipe options (keep enrollment or user data) apply to Windows devices only, and this device is not Windows. Nothing was sent.")
            }
        } catch {
            let reason = (error as? GraphError).map { $0.localizedDescription } ?? error.localizedDescription
            return fail(&operation, "Could not verify the device before \(verb), so nothing was sent. \(reason)",
                        status: (error as? GraphError)?.httpStatus)
        }

        // Last gate: a sign-out or user change during the re-read cancels the run, and nothing may be sent after that.
        guard !Task.isCancelled else {
            operation.state = .skipped
            operation.message = "Not sent: the run was cancelled before the request."
            return
        }
        // 3. Single, never-retried request.
        operation.state = .executing
        await onUpdate(operation)
        switch planned.action {
        case .mdmWipe:
            await submitWipe(deviceID: deviceID, options: planned.wipeOptions,
                             unlockCode: isMac ? MacUnlockCode.generate() : nil, into: &operation)
        case .retireDevice:
            await submitRetire(deviceID: deviceID, into: &operation)
        case .deleteIntuneRecord:
            await submitDelete(deviceID: deviceID, into: &operation)
        case .noAction, .mamSelectiveWipe:
            fail(&operation, "Internal error: not a device action. Nothing was sent.")
        }
    }

    // MARK: - Wipe

    private func submitWipe(deviceID: String, options: WipeOptions, unlockCode: String?,
                            into operation: inout OperationResult) async {
        let pinNote = unlockCode == nil ? "" : " A six-digit unlock PIN was set for this Mac (shown here only; Intune also "
            + "shows it on the device page until the wipe completes)."
        do {
            let status = try await actions.wipe(deviceID: deviceID, options: options, macOsUnlockCode: unlockCode)
            operation.macOsUnlockCode = unlockCode
            operation.state = .submitted
            operation.httpStatus = status
            operation.message = "Wipe request accepted by Intune (HTTP \(status)). This does not mean the device has been erased yet; "
                + "check its status in Intune."
                + (options.isFullWipe ? "" : " The wipe was sent with: \(options.summary).")
                + pinNote
            log.info("Wipe submitted for managed device \(deviceID), HTTP \(status)")
        } catch GraphError.outcomeUnknown(let detail) {
            operation.state = .outcomeUnknown
            operation.macOsUnlockCode = unlockCode // the wipe may have gone through, so keep the PIN visible
            operation.message = "The wipe request was sent but its outcome is unknown (\(detail)). "
                + "Check the device in Intune before trying again. It was NOT retried."
            log.error("Wipe outcome unknown for managed device \(deviceID)")
        } catch {
            let graphError = error as? GraphError
            fail(&operation, graphError?.localizedDescription ?? error.localizedDescription, status: graphError?.httpStatus)
            log.error("Wipe failed for managed device \(deviceID): \(operation.message)")
        }
    }

    // MARK: - Retire

    private func submitRetire(deviceID: String, into operation: inout OperationResult) async {
        do {
            let status = try await actions.retire(deviceID: deviceID)
            operation.state = .submitted
            operation.httpStatus = status
            operation.message = "Retire request accepted by Intune (HTTP \(status)). Company data and management are removed "
                + "when the device next checks in; until then the retire is pending. Check its status in Intune."
            log.info("Retire submitted for managed device \(deviceID), HTTP \(status)")
        } catch GraphError.outcomeUnknown(let detail) {
            operation.state = .outcomeUnknown
            operation.message = "The retire request was sent but its outcome is unknown (\(detail)). "
                + "Check the device in Intune before trying again. It was NOT retried."
            log.error("Retire outcome unknown for managed device \(deviceID)")
        } catch {
            let graphError = error as? GraphError
            fail(&operation, graphError?.localizedDescription ?? error.localizedDescription, status: graphError?.httpStatus)
            log.error("Retire failed for managed device \(deviceID): \(operation.message)")
        }
    }

    // MARK: - Delete

    private func submitDelete(deviceID: String, into operation: inout OperationResult) async {
        do {
            let status = try await actions.deleteRecord(deviceID: deviceID)
            operation.httpStatus = status
            log.info("Delete submitted for managed device \(deviceID), HTTP \(status)")
            switch await recordState(deviceID) {
            case .gone:
                operation.state = .succeeded
                operation.message = "Intune record deleted (HTTP \(status)) and confirmed gone. This is a record delete, not a device wipe."
            case .stillThere, .unchecked:
                operation.state = .submitted
                operation.message = "Delete request accepted by Intune (HTTP \(status)), but the record could not yet be confirmed gone. "
                    + "Check the device in Intune."
            }
        } catch GraphError.outcomeUnknown(let detail) {
            log.error("Delete outcome unknown for managed device \(deviceID)")
            // The reply was lost. One read (not a retry of the delete) can still settle it.
            if await recordState(deviceID) == .gone {
                operation.state = .succeeded
                operation.message = "The delete reply was lost (\(detail)), but the Intune record no longer exists."
            } else {
                operation.state = .outcomeUnknown
                operation.message = "The delete request was sent but its outcome is unknown (\(detail)). "
                    + "Check the device in Intune before trying again. It was NOT retried."
            }
        } catch {
            let graphError = error as? GraphError
            fail(&operation, graphError?.localizedDescription ?? error.localizedDescription, status: graphError?.httpStatus)
            log.error("Delete failed for managed device \(deviceID): \(operation.message)")
        }
    }

    private enum RecordState { case gone, stillThere, unchecked }

    /// One read after a delete: 404 means the record is gone; any other failure proves nothing.
    private func recordState(_ deviceID: String) async -> RecordState {
        do {
            _ = try await actions.currentDevice(id: deviceID)
            return .stillThere
        } catch GraphError.notFound {
            return .gone
        } catch {
            return .unchecked
        }
    }

    // MARK: - MAM selective wipe

    private func performSelectiveWipe(
        _ planned: PlannedAction, plan: OffboardingPlan, into operation: inout OperationResult,
        onUpdate: @Sendable (OperationResult) async -> Void
    ) async {
        guard let mam, case .mamDeviceGroup(let groupID) = planned.asset else {
            return fail(&operation, "Internal error: a selective wipe was requested for a non-MAM asset. Nothing was sent.")
        }
        // Re-verify right before sending: the device group must still exist with the same registrations.
        operation.state = .validating
        await onUpdate(operation)
        let tag: String
        do {
            let groups = try await mam.currentGroups(for: plan.user)
            guard let group = groups.first(where: { $0.id == groupID }) else {
                return fail(&operation, "These app-protection registrations no longer exist for \(plan.user.userPrincipalName). Nothing was sent.")
            }
            guard let deviceTag = group.deviceTag, !deviceTag.isEmpty else {
                return fail(&operation, "These registrations have no device tag, so a selective wipe is not possible. Nothing was sent.")
            }
            let now = PlannedAction.Fingerprint.mamGroup(registrationIDs: group.registrations.map(\.id).sorted())
            guard now == planned.fingerprint else {
                return fail(&operation, "The set of app-protection registrations on this device changed since review. Nothing was sent.")
            }
            tag = deviceTag
        } catch {
            let reason = (error as? GraphError).map { $0.localizedDescription } ?? error.localizedDescription
            return fail(&operation, "Could not verify the registrations before the selective wipe, so nothing was sent. \(reason)",
                        status: (error as? GraphError)?.httpStatus)
        }

        guard !Task.isCancelled else {
            operation.state = .skipped
            operation.message = "Not sent: the run was cancelled before the request."
            return
        }
        // Single, never-retried request.
        operation.state = .executing
        await onUpdate(operation)
        do {
            let status = try await mam.selectiveWipe(userID: plan.user.id, deviceTag: tag)
            operation.state = .submitted
            operation.httpStatus = status
            operation.message = "Selective wipe request accepted by Intune (HTTP \(status)). This does not mean the app data has been removed yet; "
                + "check the app-protection status in Intune."
            log.info("MAM selective wipe submitted for group \(groupID), HTTP \(status)")
        } catch GraphError.outcomeUnknown(let detail) {
            operation.state = .outcomeUnknown
            operation.message = "The selective wipe request was sent but its outcome is unknown (\(detail)). "
                + "Check the registrations in Intune before trying again. It was NOT retried."
            log.error("MAM selective wipe outcome unknown for group \(groupID)")
        } catch {
            let graphError = error as? GraphError
            fail(&operation, graphError?.localizedDescription ?? error.localizedDescription, status: graphError?.httpStatus)
            log.error("MAM selective wipe failed for group \(groupID): \(operation.message)")
        }
    }

    private func fail(_ operation: inout OperationResult, _ message: String, status: Int? = nil) {
        operation.state = .failed
        operation.message = message
        operation.httpStatus = status
    }
}
