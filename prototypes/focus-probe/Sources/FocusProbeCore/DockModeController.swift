import Foundation

/// 사용 모드 전환을 한 곳에서 관리한다.
///
/// 적용 순서(승인된 순서 그대로):
/// 1) 원래 설정 확인 → 2) 복구 정보 기록 → 3) 커스텀 화면 준비(**준비 완료 확인까지**) →
/// 4) 필요한 설정 적용 → 5) 값 확인 → 6) Dock 재시작.
///
/// 지키는 것:
/// - 동의 없이는 아무것도 바꾸지 않는다.
/// - **바꾼 키만** 되돌리고, 되돌리기는 **실제 값을 다시 읽어 확인**한다.
/// - 사용자가 실행 중 바꾼 값은 덮어쓰지 않고, 그 사실을 기록에 남긴다.
/// - 기록·잠금의 실패를 무시하지 않는다(무엇이 실패했는지 결과에 담는다).
public final class DockModeController {
    private let system: DockSystemControl
    private let recovery: DockRecoveryStore
    private let lock: DockModeLock
    private let plan: DockModePlan
    private let log: (String) -> Void
    private let now: () -> Date
    private let pid: Int32
    private let bootID: String
    private let lease: TimeInterval
    private let isProcessAlive: (Int32) -> Bool

    public private(set) var applied: DockAppliedState = .none
    public private(set) var isBusy = false
    /// 잠금을 이어받았을 때 남긴 설명(화면·명령줄에서 안내).
    public private(set) var lastLockNote: String?

    public init(
        system: DockSystemControl,
        recovery: DockRecoveryStore,
        lock: DockModeLock = DockModeLock(url: nil),
        plan: DockModePlan = .systemDefault,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        bootID: String = DockBootID.current(),
        lease: TimeInterval = 600,
        isProcessAlive: @escaping (Int32) -> Bool = DockModeLock.isAlive,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.system = system
        self.recovery = recovery
        self.lock = lock
        self.plan = plan
        self.pid = pid
        self.bootID = bootID
        self.lease = lease
        self.isProcessAlive = isProcessAlive
        self.now = now
        self.log = log
    }

    // MARK: - 적용

    /// Custom 적용. `consent`가 false면 **아무것도 하지 않는다**(동의 없이는 시스템 설정을 바꾸지 않는다).
    /// `suppressionApproved`는 문서화되지 않은 억제 설정 사용 동의다(별도 승인).
    ///
    /// - `prepareScreen`은 **화면이 실제로 준비됐음을 확인한 뒤** 돌아와야 한다. 실패하면 설정을 바꾸지 않는다.
    public func applyCustom(
        consent: Bool,
        suppressionApproved: Bool,
        prepareScreen: () throws -> Void
    ) throws -> DockModeOutcome {
        guard consent else { throw DockModeError.notConsented }
        guard !isBusy else { throw DockModeError.busy }
        isBusy = true
        defer { isBusy = false }

        let moment = now()
        let operationID = UUID().uuidString
        var notes: [String] = []

        notes.append(contentsOf: try acquireLock(operationID: operationID, purpose: "apply", moment: moment))
        defer { releaseLock(operationID: operationID, notes: &notes) }

        let changes = plan.changes(includeSuppression: suppressionApproved)
        let snapshot = system.snapshot(changes.map(\.key))

        // 적용이 **실제로 바꾸는** 키만 기록한다(이미 원하는 값이면 건드리지 않는다).
        var entries: [DockRecoveryRecord.Entry] = []
        var pending: [DockChange] = []
        for change in changes {
            let current = system.currentValue(for: change.key)
            if let current, current.matches(change.value) {
                notes.append("\(change.key.label)은(는) 이미 원하는 값(\(change.value.text))입니다 — 건드리지 않습니다")
                continue
            }
            pending.append(change)
            entries.append(
                DockRecoveryRecord.Entry(
                    domain: change.key.domain,
                    name: change.key.name,
                    original: (snapshot.original(for: change.key) ?? nil).map(DockRecoveryRecord.StoredValue.init),
                    applied: DockRecoveryRecord.StoredValue(change.value)
                )
            )
        }

        let record = DockRecoveryRecord(
            operationID: operationID,
            mode: DockMode.custom.rawValue,
            appliedAt: moment,
            updatedAt: moment,
            suppression: suppressionApproved,
            entries: entries,
            ownerPID: pid,
            bootID: bootID
        )

        // 이미 원하는 상태면 기록할 것이 없다 — 기록 없이 적용 완료로 본다.
        if !pending.isEmpty {
            switch recovery.create(record) {
            case .written:
                log("dockmode recovery=written op=\(operationID.prefix(8)) keys=\(entries.count) suppression=\(suppressionApproved)")
            case .refusedPendingRestore(let keys):
                log("dockmode apply result=refused reason=pending keys=\(keys.count)")
                throw DockModeError.recoveryRecordPending(keys.joined(separator: ","))
            case .refusedUnreadable(let reason):
                // 손상된 기록은 **원본을 보존**하고 적용도 거부한다(그 파일이 복구 단서다).
                log("dockmode apply result=refused reason=unreadable")
                throw DockModeError.recoveryRecordPending("복구 기록을 읽을 수 없습니다(\(reason)) — 원본을 지우지 않았습니다")
            case .failed(let reason):
                log("dockmode apply result=refused reason=record")
                throw DockModeError.recoveryRecordUnavailable(reason)
            case .noPath:
                log("dockmode apply result=refused reason=no-path")
                throw DockModeError.recoveryRecordUnavailable("복구 기록 경로가 없습니다")
            }
        } else {
            log("dockmode apply note=already-in-desired-state")
        }

        // 3) 화면 준비 — **준비 완료를 확인한 뒤에만** 시스템 설정을 건드린다.
        do {
            try prepareScreen()
        } catch {
            if !pending.isEmpty {
                let clear = recovery.clear(operationID: operationID)
                if !clear.isClean {
                    let reason = clear.failureReason ?? "-"
                    notes.append("복구 기록 정리 실패: \(reason)")
                    log("dockmode apply cleanup=failed reason=\(reason)")
                }
            }
            log("dockmode apply result=failed step=prepare")
            throw DockModeError.applyFailed(step: "커스텀 화면 준비", reason: Self.describe(error))
        }

        // 4) 적용 → 5) 확인
        var touched: [DockPreferenceKey] = []
        var appliedKeys: [String] = []
        do {
            for change in pending {
                // **쓰기 시도 전에** 되돌릴 목록에 넣는다. 값이 바뀐 뒤 오류를 던지는 구현에서도
                // 그 키가 되돌리기에서 빠지지 않는다.
                touched.append(change.key)
                try system.set(change.value, for: change.key)
                _ = lock.refresh(operationID: operationID, now: now())
                let current = system.currentValue(for: change.key)
                guard let current, current.matches(change.value) else {
                    throw DockModeError.applyFailed(
                        step: "설정 확인",
                        reason: "\(change.key.label) 값이 적용되지 않았습니다"
                    )
                }
                appliedKeys.append(change.key.label)
            }
            try system.restartDock()
        } catch {
            let rollback = rollback(touched: touched, record: record)
            notes.append(contentsOf: rollback.notes)
            if rollback.failed.isEmpty {
                // 값 확인까지 끝난 되돌리기만 성공으로 본다.
                if !pending.isEmpty {
                    let clear = recovery.clear(operationID: operationID)
                    if !clear.isClean {
                        let reason = clear.failureReason ?? "-"
                        notes.append("복구 기록 정리 실패: \(reason)")
                        log("dockmode apply cleanup=failed reason=\(reason)")
                    }
                }
                log("dockmode apply result=rolledback keys=\(rollback.verified.count)")
                throw DockModeError.applyFailed(step: Self.stepName(error), reason: Self.describe(error))
            }
            // 되돌리지 못한 키가 있다 — **기록을 남긴다**(그 키들만).
            let leftover = record.entries.filter { rollback.failed.contains($0.keyLabel) }
            let updated = DockRecoveryRecord(
                operationID: operationID,
                mode: record.mode,
                appliedAt: record.appliedAt,
                updatedAt: now(),
                suppression: record.suppression,
                entries: leftover.map { entry in
                    var copy = entry
                    copy.skipReason = "rollbackFailed"
                    return copy
                },
                ownerPID: record.ownerPID,
                bootID: record.bootID
            )
            switch recovery.update(updated) {
            case .written:
                notes.append("되돌리지 못한 키를 기록에 남겼습니다: \(leftover.map(\.keyLabel).joined(separator: ","))")
            case .refusedPendingRestore(let keys):
                notes.append("기록 갱신 거부(다른 작업의 미복원 기록): \(keys.joined(separator: ","))")
                log("dockmode apply record-update=refused pending")
            case .refusedUnreadable(let reason):
                notes.append("기록 갱신 거부(읽을 수 없음): \(reason)")
                log("dockmode apply record-update=refused unreadable")
            case .failed(let reason):
                notes.append("기록 갱신 실패: \(reason)")
                log("dockmode apply record-update=failed reason=\(reason)")
            case .noPath:
                notes.append("기록 갱신 실패: 경로 없음")
                log("dockmode apply record-update=failed no-path")
            }
            log("dockmode apply result=rollback-failed keys=\(rollback.failed.count)")
            throw DockModeError.rollbackFailed("\(Self.describe(error)) (되돌리지 못한 키 \(rollback.failed.count)개)")
        }

        applied = .custom(appliedAt: moment, suppression: suppressionApproved)
        log("dockmode apply result=ok keys=\(appliedKeys.count) op=\(operationID.prefix(8))")
        return DockModeOutcome(
            applied: applied,
            changedKeys: appliedKeys,
            recoveryRecordLeft: !pending.isEmpty,
            lockNote: lastLockNote,
            notes: notes
        )
    }

    // MARK: - 복원

    /// Mac Dock 복귀. **정상 종료·비정상 종료 복구가 같은 경로**를 쓴다.
    ///
    /// 처분을 구분해 돌려준다: 복원 / 이미 원래 값 / 사용자 변경 / 키 삭제 / 실패.
    /// 부분 복원이나 실패를 **성공으로 뭉개지 않는다.**
    public func restoreToMacDock() throws -> DockRestoreOutcome {
        guard !isBusy else { throw DockModeError.busy }
        isBusy = true
        defer { isBusy = false }

        let loaded = recovery.loadResult()
        if case .unreadable(let reason) = loaded {
            applied = .none
            throw DockModeError.restoreRecordUnreadable(reason)
        }
        guard let record = loaded.record else {
            applied = .none
            return DockRestoreOutcome(kind: .nothingToDo, notes: [loaded.summary])
        }

        let moment = now()
        let operationID = UUID().uuidString
        var notes: [String] = []
        notes.append(contentsOf: try acquireLock(operationID: operationID, purpose: "restore", moment: moment))
        defer { releaseLock(operationID: operationID, notes: &notes) }

        var results: [DockRestoreEntryResult] = []
        var remaining: [DockRecoveryRecord.Entry] = []

        func keep(_ entry: DockRecoveryRecord.Entry, _ disposition: DockRestoreDisposition, _ detail: String) {
            results.append(DockRestoreEntryResult(key: entry.keyLabel, disposition: disposition, detail: detail))
            var updated = entry
            updated.skippedByUserChange = (disposition == .userChanged)
            updated.skipReason = disposition.rawValue
            remaining.append(updated)
        }

        for entry in record.entries {
            let key = DockPreferenceKey(domain: entry.domain, name: entry.name)
            let appliedValue = entry.applied.asValue
            let current = system.currentValue(for: key)

            if entry.skippedByUserChange {
                keep(entry, .userChanged, "이전 복원에서 사용자 변경으로 표시됨")
                continue
            }
            if current == nil, entry.original == nil {
                // 우리가 만들었던 키가 없고 원래도 없던 키 — 되돌릴 것이 없다.
                results.append(DockRestoreEntryResult(key: entry.keyLabel, disposition: .alreadyOriginal, detail: "원래도 없던 키"))
                continue
            }
            if let current, let original = entry.original, current.matches(original.asValue) {
                results.append(DockRestoreEntryResult(key: entry.keyLabel, disposition: .alreadyOriginal, detail: "현재 값이 원래 값과 같음"))
                continue
            }
            if let current, !current.matches(appliedValue) {
                keep(entry, .userChanged, "현재 \(current.text) ≠ 적용값 \(appliedValue.text)")
                log("dockmode restore skip=\(key.label) (사용자 변경)")
                continue
            }
            if current == nil, entry.original != nil {
                keep(entry, .keyRemoved, "키가 없어졌습니다(사용자 삭제로 보고 만들지 않음)")
                log("dockmode restore skip=\(key.label) (키 삭제됨)")
                continue
            }

            var writeError: String?
            do {
                if let original = entry.original {
                    try system.set(original.asValue, for: key)
                } else {
                    // 원래 없던 키는 지운다.
                    try system.remove(key)
                }
            } catch {
                // **쓰기가 오류를 냈어도 값은 바뀌었을 수 있다.** 반환값이 아니라 실제 값으로 판정한다.
                writeError = Self.describe(error)
                log("dockmode restore write-error=\(key.label)")
            }
            _ = lock.refresh(operationID: operationID, now: now())

            let check = system.currentValue(for: key)
            let expected = entry.original?.asValue
            let verified: Bool = {
                guard let expected else { return check == nil }
                return check?.matches(expected) ?? false
            }()
            if verified, let writeError {
                results.append(
                    DockRestoreEntryResult(
                        key: entry.keyLabel,
                        disposition: .restored,
                        detail: "쓰기 오류 뒤 값 확인됨: \(writeError)"
                    )
                )
            } else if verified {
                results.append(
                    DockRestoreEntryResult(
                        key: entry.keyLabel,
                        disposition: .restored,
                        detail: expected.map { "→ \($0.text)" } ?? "키 삭제"
                    )
                )
            } else {
                keep(entry, .failed, writeError.map { "쓰기 실패·확인 실패(\($0))" } ?? "확인 실패(현재 \(check?.text ?? "없음"))")
                log("dockmode restore unverified=\(key.label)")
            }
        }

        // 되돌린 키가 있거나 지난번 재시작이 남아 있으면 Dock을 한 번 다시 시작한다.
        let restoredCount = results.filter { $0.disposition == .restored }.count
        var restartPerformed = false
        var restartPending = record.restartPending
        if restoredCount > 0 || record.restartPending {
            do {
                try system.restartDock()
                restartPerformed = true
                restartPending = false
            } catch {
                restartPending = true
                notes.append("Dock 재시작 실패: \(Self.describe(error))")
                log("dockmode restore restart=failed")
            }
        }

        let alreadyCount = results.filter { $0.disposition == .alreadyOriginal }.count
        let failedCount = results.filter { $0.disposition == .failed }.count
        // 구분 규칙:
        // - 완전 복원: 남은 키도, 미뤄 둔 재시작도 없다.
        // - 실패: 되돌리지 못한 키가 있고 **아무것도 진행하지 못했다**(되돌리기 실패가 원인).
        // - 부분: 그 밖에 남은 것이 있다(사용자 변경·키 삭제는 사용자의 결정이므로 실패가 아니다).
        var kind: DockRestoreKind
        if remaining.isEmpty, !restartPending {
            kind = .complete
        } else if failedCount > 0, restoredCount == 0, alreadyCount == 0 {
            kind = .failed
        } else {
            kind = .partial
        }

        var recordStillOnDisk = !remaining.isEmpty
        if remaining.isEmpty, !restartPending {
            // **복원 확인 뒤에만** 지운다. 지우지 못하면 그대로 알린다.
            let clear = recovery.clear(operationID: record.operationID)
            if !clear.isClean {
                let reason = clear.failureReason ?? "-"
                notes.append("복구 기록 정리 실패: \(reason)")
                recordStillOnDisk = true
                log("dockmode restore cleanup=failed reason=\(reason)")
            } else {
                log("dockmode restore result=complete restored=\(restoredCount)")
            }
        } else {
            let updated = DockRecoveryRecord(
                operationID: record.operationID,
                mode: record.mode,
                appliedAt: record.appliedAt,
                updatedAt: now(),
                suppression: record.suppression,
                entries: remaining,
                ownerPID: record.ownerPID,
                bootID: record.bootID,
                restartPending: restartPending
            )
            switch recovery.update(updated) {
            case .written:
                log("dockmode restore result=partial restored=\(restoredCount) left=\(remaining.count) restartPending=\(restartPending)")
            case .refusedPendingRestore(let keys):
                notes.append("기록 갱신 거부(다른 작업의 미복원 기록): \(keys.joined(separator: ","))")
                kind = .partial
                log("dockmode restore record-update=refused pending")
            case .refusedUnreadable(let reason):
                notes.append("기록 갱신 거부(읽을 수 없음): \(reason)")
                kind = .partial
                log("dockmode restore record-update=refused unreadable")
            case .failed(let reason):
                notes.append("기록 갱신 실패: \(reason)")
                kind = kind == .complete ? .partial : kind
                log("dockmode restore record-update=failed reason=\(reason)")
            case .noPath:
                notes.append("기록 갱신 실패: 경로 없음")
                kind = kind == .complete ? .partial : kind
                log("dockmode restore record-update=failed no-path")
            }
        }

        applied = .none
        if kind == .partial {
            notes.append("남은 키: " + remaining.map { "\($0.keyLabel)(\($0.skipReason ?? "-"))" }.joined(separator: ", "))
        }
        return DockRestoreOutcome(
            kind: kind,
            entries: results,
            recordLeft: recordStillOnDisk,
            restartPerformed: restartPerformed,
            notes: notes
        )
    }

    // MARK: - 상태

    /// 복구 기록 읽기 결과(손상 포함). 화면·명령줄에서 그대로 안내한다.
    public func recoveryState() -> DockRecoveryLoad { recovery.loadResult() }

    /// 다음 실행에서 **복구 상태를 감지**한다(자동 복원이 아니라 감지 + 안내).
    public func detectStaleRecord() -> DockRecoveryRecord? {
        guard let record = recovery.load() else { return nil }
        log("dockmode detect stale op=\(record.operationID.prefix(8)) keys=\(record.entries.count) owner=\(record.ownerPID)")
        return record
    }

    /// 지금 잠금을 누가 잡고 있는가(화면 안내용).
    public func lockOwner() -> DockLockInfo? { lock.current() }

    // MARK: - 잠금

    /// 잠금을 잡는다. 살아 있는 다른 인스턴스의 잠금은 **지우지 않고** 오류로 알린다.
    /// 반환값은 안내 문구(이어받았을 때 원본 보존 경로 등).
    private func acquireLock(operationID: String, purpose: String, moment: Date) throws -> [String] {
        let info = DockLockInfo(
            ownerPID: pid,
            operationID: operationID,
            purpose: purpose,
            bootID: bootID,
            recordedAt: moment
        )
        var notes: [String] = []
        switch lock.acquire(info, lease: lease, isProcessAlive: isProcessAlive) {
        case .acquired, .noPath:
            lastLockNote = nil
        case .heldByOther(let other):
            let note = "다른 인스턴스(pid=\(other.ownerPID))가 \(other.purpose) 중"
            lastLockNote = note
            log("dockmode lock=held-by-other pid=\(other.ownerPID)")
            throw DockModeError.otherInstanceActive(note)
        case .tookOverStale(let other, let preserved):
            let note = "이전 잠금(pid=\(other.ownerPID), \(other.purpose))을 이어받았습니다"
                + (preserved.map { " — 원본 보존: \($0)" } ?? "")
            lastLockNote = note
            notes.append(note)
            log("dockmode lock=took-over pid=\(other.ownerPID)")
        case .unavailable(let reason):
            throw DockModeError.lockUnavailable(reason)
        }
        return notes
    }

    private func releaseLock(operationID: String, notes: inout [String]) {
        switch lock.release(operationID: operationID) {
        case .removed, .absent, .noPath:
            break
        case .notOwner:
            // 다른 작업이 잡고 있다 — 지우지 않는다(그 작업의 소유권이다).
            log("dockmode lock=release-skipped (다른 작업 소유)")
        case .failed(let reason):
            notes.append("잠금 해제 실패: \(reason)")
            log("dockmode lock=release-failed reason=\(reason)")
        }
    }

    // MARK: - 되돌리기

    private struct RollbackResult {
        var verified: [String] = []
        var failed: [String] = []
        var notes: [String] = []
    }

    /// 되돌리기는 **반환 여부가 아니라 실제 값**으로 판정한다.
    private func rollback(touched: [DockPreferenceKey], record: DockRecoveryRecord) -> RollbackResult {
        var result = RollbackResult()
        for key in touched {
            guard let entry = record.entries.first(where: { $0.domain == key.domain && $0.name == key.name }) else {
                continue
            }
            var writeError: String?
            do {
                if let original = entry.original {
                    try system.set(original.asValue, for: key)
                } else {
                    try system.remove(key)
                }
            } catch {
                // 쓰기 오류 뒤에도 값이 되돌아갔을 수 있다 — 실제 값을 확인한다.
                writeError = Self.describe(error)
                log("dockmode rollback write-error key=\(key.label)")
            }
            let current = system.currentValue(for: key)
            let expected = entry.original?.asValue
            let verified: Bool = {
                guard let expected else { return current == nil }
                return current?.matches(expected) ?? false
            }()
            if verified {
                result.verified.append(key.label)
                if let writeError {
                    result.notes.append("\(key.label) 쓰기 오류 뒤 값은 되돌아갔다: \(writeError)")
                }
            } else {
                result.failed.append(key.label)
                result.notes.append(
                    writeError.map { "\(key.label) 되돌리기 실패: \($0)" }
                        ?? "\(key.label) 되돌림 확인 실패(현재 \(current?.text ?? "없음"))"
                )
                log("dockmode rollback unverified key=\(key.label)")
            }
        }
        return result
    }

    // MARK: - 보조

    static func describe(_ error: Error) -> String {
        if let mode = error as? DockModeError { return mode.message }
        return (error as NSError).localizedDescription
    }

    static func stepName(_ error: Error) -> String {
        if case .applyFailed(let step, _)? = error as? DockModeError { return step }
        return "적용"
    }
}
