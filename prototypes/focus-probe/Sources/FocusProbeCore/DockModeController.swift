import Foundation

/// 복구 기록. **비정상 종료 뒤에도 남아 있어야** 다음 실행에서 복구할 수 있다.
public struct DockRecoveryRecord: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var domain: String
        public var name: String
        /// 원래 값(없던 키면 nil).
        public var original: StoredValue?
        /// 우리가 적용한 값.
        public var applied: StoredValue
        /// 사용자가 실행 중 직접 바꿔서 **복원하지 않은** 키인가.
        public var skippedByUserChange: Bool
    }

    /// 저장용 값 표현(자료형을 함께 남긴다).
    public enum StoredValue: Codable, Equatable, Sendable {
        case bool(Bool)
        case integer(Int)
        case double(Double)
        case string(String)

        public init(_ value: DockPreferenceValue) {
            switch value {
            case .bool(let inner): self = .bool(inner)
            case .integer(let inner): self = .integer(inner)
            case .double(let inner): self = .double(inner)
            case .string(let inner): self = .string(inner)
            }
        }

        public var text: String {
            switch self {
            case .bool(let inner): return inner ? "true" : "false"
            case .integer(let inner): return String(inner)
            case .double(let inner): return String(inner)
            case .string(let inner): return inner
            }
        }

        public var asValue: DockPreferenceValue {
            switch self {
            case .bool(let inner): return .bool(inner)
            case .integer(let inner): return .integer(inner)
            case .double(let inner): return .double(inner)
            case .string(let inner): return .string(inner)
            }
        }
    }

    public var mode: String
    public var appliedAt: Date
    public var suppression: Bool
    public var entries: [Entry]
    /// 이 기록을 만든 프로세스(중복 인스턴스 확인용).
    public var ownerPID: Int32

    public init(mode: String, appliedAt: Date, suppression: Bool, entries: [Entry], ownerPID: Int32) {
        self.mode = mode
        self.appliedAt = appliedAt
        self.suppression = suppression
        self.entries = entries
        self.ownerPID = ownerPID
    }

    /// 아직 복원하지 않은 키가 있는가.
    public var hasUnrestoredKeys: Bool { entries.contains { !$0.skippedByUserChange } }
}

/// 복구 기록을 파일로 보관한다(경로 주입 가능 — 검사는 임시 경로를 쓴다).
/// 복구 기록 읽기 결과. **손상을 '기록 없음'으로 뭉개지 않는다**(복구 수단이 조용히 사라지면 안 된다).
public enum DockRecoveryLoad: Equatable, Sendable {
    case none
    case record(DockRecoveryRecord)
    /// 파일은 있는데 읽을 수 없다(손상·권한·잘못된 JSON). 파일은 **지우지 않는다**.
    case unreadable(reason: String)
    case noPath
}

public struct DockRecoveryStore: Sendable {
    public var url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func load() -> DockRecoveryRecord? {
        if case .record(let record) = loadResult() { return record }
        return nil
    }

    /// 읽기 결과를 구분해 돌려준다(손상 vs 없음).
    public func loadResult() -> DockRecoveryLoad {
        guard let url else { return .noPath }
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(reason: "파일을 읽을 수 없습니다")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .record(try decoder.decode(DockRecoveryRecord.self, from: data))
        } catch {
            return .unreadable(reason: "형식이 맞지 않습니다")
        }
    }

    /// 기록한다. **미복원 기록이 있으면 덮어쓰지 않는다**(원본을 잃지 않게).
    @discardableResult
    public func save(_ record: DockRecoveryRecord) -> Bool {
        guard let url else { return false }
        if let existing = load(), existing.hasUnrestoredKeys { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 복원을 확인한 뒤에만 기록을 지운다.
    public func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// 중복 인스턴스가 서로 설정을 바꾸지 못하게 하는 잠금(파일 존재 기반).
public struct DockModeLock: Sendable {
    public var url: URL?

    public init(url: URL?) {
        self.url = url
    }

    /// 잠금을 잡는다. 이미 있으면 false(다른 인스턴스가 적용 중).
    public func acquire(ownerPID: Int32) -> Bool {
        guard let url else { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = "\(ownerPID)"
        if FileManager.default.fileExists(atPath: url.path) {
            // 같은 프로세스가 다시 잡는 것은 허용한다(재진입).
            if let text = try? String(contentsOf: url, encoding: .utf8), text == payload { return true }
            return false
        }
        return (try? Data(payload.utf8).write(to: url, options: .atomic)) != nil
    }

    public func release() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// 모드 적용의 결과(검사·로그용).
public struct DockModeOutcome: Equatable, Sendable {
    public var applied: DockAppliedState
    public var changedKeys: [String]
    public var rolledBackKeys: [String]
    public var skippedByUserChange: [String]
    public var recoveryRecordLeft: Bool
    public var notes: [String]
}

/// 사용 모드 전환을 한 곳에서 관리한다.
///
/// 적용 순서(승인된 순서 그대로):
/// 1) 원래 설정 확인 → 2) 복구 정보 기록 → 3) 커스텀 화면 준비 → 4) 필요한 설정 적용 → 5) 숨김 확인 → 6) 완료.
/// 3~5단계에서 실패하면 **이미 적용한 변경을 되돌린다.** 2단계에서 실패하면 **아무것도 바꾸지 않는다.**
public final class DockModeController {
    private let system: DockSystemControl
    private let recovery: DockRecoveryStore
    private let lock: DockModeLock
    private let plan: DockModePlan
    private let log: (String) -> Void
    private let now: () -> Date
    private let pid: Int32

    public private(set) var applied: DockAppliedState = .none
    public private(set) var isBusy = false

    public init(
        system: DockSystemControl,
        recovery: DockRecoveryStore,
        lock: DockModeLock = DockModeLock(url: nil),
        plan: DockModePlan = .systemDefault,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.system = system
        self.recovery = recovery
        self.lock = lock
        self.plan = plan
        self.pid = pid
        self.now = now
        self.log = log
    }

    /// Custom 적용. `consent`가 false면 **아무것도 하지 않는다**(동의 없이는 시스템 설정을 바꾸지 않는다).
    /// `suppressionApproved`는 문서화되지 않은 억제 설정 사용 동의다(별도 승인).
    public func applyCustom(
        consent: Bool,
        suppressionApproved: Bool,
        prepareScreen: () throws -> Void
    ) throws -> DockModeOutcome {
        guard consent else { throw DockModeError.notConsented }
        guard !isBusy else { throw DockModeError.busy }
        isBusy = true
        defer { isBusy = false }

        guard lock.acquire(ownerPID: pid) else { throw DockModeError.otherInstanceActive }
        defer { lock.release() }

        var notes: [String] = []
        let changes = plan.changes(includeSuppression: suppressionApproved)

        // 1) 원래 설정 확인 + 2) 복구 정보 기록 (실패하면 시스템을 건드리지 않는다)
        let snapshot = system.snapshot(changes.map(\.key))
        let record = DockRecoveryRecord(
            mode: DockMode.custom.rawValue,
            appliedAt: now(),
            suppression: suppressionApproved,
            entries: changes.map { change in
                DockRecoveryRecord.Entry(
                    domain: change.key.domain,
                    name: change.key.name,
                    original: (snapshot.original(for: change.key) ?? nil).map(DockRecoveryRecord.StoredValue.init),
                    applied: DockRecoveryRecord.StoredValue(change.value),
                    skippedByUserChange: false
                )
            },
            ownerPID: pid
        )
        guard recovery.save(record) else {
            let reason = recovery.url == nil ? "복구 기록 경로가 없습니다" : "복구 기록을 쓰지 못했습니다"
            notes.append(reason)
            log("dockmode apply result=refused reason=\(reason)")
            throw DockModeError.recoveryRecordUnavailable(reason)
        }
        log("dockmode recovery=written keys=\(changes.count) suppression=\(suppressionApproved)")

        // 3) 커스텀 화면 준비 — 실패하면 아직 바꾼 것이 없다.
        do {
            try prepareScreen()
        } catch {
            recovery.clear()
            log("dockmode apply result=failed step=prepare")
            throw DockModeError.applyFailed(step: "커스텀 화면 준비", reason: "\(error)")
        }

        // 4) 필요한 설정 적용 → 5) 확인
        var appliedKeys: [String] = []
        do {
            for change in changes {
                try system.set(change.value, for: change.key)
                appliedKeys.append(change.key.label)
                let current = system.currentValue(for: change.key)
                guard current == change.value else {
                    throw DockModeError.applyFailed(step: "설정 확인", reason: "\(change.key.label) 값이 적용되지 않았습니다")
                }
            }
            try system.restartDock()
        } catch {
            // 되돌린다 — 복구 기록의 **원래 값**만 사용하고, 실제로 바꾼 키만 되돌린다.
            let rolledBack = rollback(appliedKeys: appliedKeys, record: record)
            if rolledBack.count == appliedKeys.count {
                recovery.clear()
                log("dockmode apply result=rolledback keys=\(rolledBack.count)")
                throw DockModeError.applyFailed(
                    step: (error as? DockModeError).map { if case .applyFailed(let step, _) = $0 { return step } else { return "적용" } } ?? "적용",
                    reason: "\(error)"
                )
            }
            log("dockmode apply result=rollback-failed")
            throw DockModeError.rollbackFailed("\(error)")
        }

        applied = .custom(appliedAt: record.appliedAt, suppression: suppressionApproved)
        log("dockmode apply result=ok keys=\(appliedKeys.joined(separator: ","))")
        return DockModeOutcome(
            applied: applied,
            changedKeys: appliedKeys,
            rolledBackKeys: [],
            skippedByUserChange: [],
            recoveryRecordLeft: true,
            notes: notes
        )
    }

    /// Mac Dock 복귀. **정상 종료와 같은 경로**를 쓴다(추후 Custom → Both에서도 재사용).
    ///
    /// - 실제로 바꾼 키만 되돌린다(없던 키는 삭제).
    /// - 사용자가 실행 중 직접 바꾼 값은 **조용히 덮어쓰지 않고** 건너뛴다(기록은 남긴다).
    /// - 같은 요청을 반복해도 사용자 설정이 손상되지 않는다.
    @discardableResult
    public func restoreToMacDock() throws -> DockModeOutcome {
        guard !isBusy else { throw DockModeError.busy }
        isBusy = true
        defer { isBusy = false }

        let loaded = recovery.loadResult()
        if case .unreadable(let reason) = loaded {
            // 손상된 기록을 '없음'으로 처리하면 사용자가 복구 수단을 잃는다. 지우지 않고 알린다.
            applied = .none
            throw DockModeError.restoreRecordUnreadable(reason)
        }
        guard case .record(let record) = loaded else {
            applied = .none
            return DockModeOutcome(applied: .none, changedKeys: [], rolledBackKeys: [], skippedByUserChange: [], recoveryRecordLeft: false, notes: ["복구 기록이 없습니다(이미 복원됨)"])
        }

        guard lock.acquire(ownerPID: pid) else { throw DockModeError.otherInstanceActive }
        defer { lock.release() }

        var skipped: [String] = []
        var restored: [String] = []
        var updated = record
        updated.entries = []

        for entry in record.entries {
            let key = DockPreferenceKey(domain: entry.domain, name: entry.name)
            let appliedValue = entry.applied.asValue
            let current = system.currentValue(for: key)
            // 사용자가 실행 중 직접 바꾼 값은 건드리지 않는다.
            if entry.skippedByUserChange || (current != nil && current != appliedValue) {
                skipped.append(key.label)
                updated.entries.append(entry)
                log("dockmode restore skip=\(key.label) (사용자 변경)")
                continue
            }
            if let original = entry.original {
                try system.set(original.asValue, for: key)
            } else {
                // 원래 없던 키는 지운다.
                try system.remove(key)
            }
            let check = system.currentValue(for: key)
            let expected = entry.original?.asValue
            guard check == expected else {
                skipped.append(key.label)
                updated.entries.append(entry)
                log("dockmode restore unverified=\(key.label)")
                continue
            }
            restored.append(key.label)
        }

        // 실제로 되돌린 키가 있을 때만 Dock을 다시 시작한다(빈 기록·전부 건너뜀일 때 괜히 흔들지 않는다).
        if restored.isEmpty {
            log("dockmode restore restart=skipped (되돌린 키 없음)")
        } else {
            try system.restartDock()
        }

        let outcome = DockModeOutcome(
            applied: .none,
            changedKeys: restored,
            rolledBackKeys: [],
            skippedByUserChange: skipped,
            recoveryRecordLeft: !updated.entries.isEmpty,
            notes: skipped.isEmpty ? [] : ["사용자 변경으로 건너뛴 키: \(skipped.joined(separator: ","))"]
        )

        if updated.entries.isEmpty {
            // **복원 성공을 확인한 뒤에만** 기록을 지운다.
            recovery.clear()
            log("dockmode restore result=ok keys=\(restored.count)")
        } else {
            // 미복원 기록은 남겨 두고 **새 원본으로 덮어쓰지 않는다.**
            recovery.save(updated)
            log("dockmode restore result=partial restored=\(restored.count) skipped=\(skipped.count)")
        }
        applied = .none
        return outcome
    }

    /// 복구 기록 읽기 결과(손상 포함). 화면·명령줄에서 그대로 안내한다.
    public func recoveryState() -> DockRecoveryLoad {
        recovery.loadResult()
    }

    /// 다음 실행에서 **복구 상태를 감지**한다(자동 복원이 아니라 감지 + 안내).
    public func detectStaleRecord() -> DockRecoveryRecord? {
        guard let record = recovery.load() else { return nil }
        log("dockmode detect stale mode=\(record.mode) keys=\(record.entries.count) owner=\(record.ownerPID)")
        return record
    }

    /// 이미 적용된 키만 되돌린다(실패 경로에서 사용).
    private func rollback(appliedKeys: [String], record: DockRecoveryRecord) -> [String] {
        var rolledBack: [String] = []
        for entry in record.entries {
            let key = DockPreferenceKey(domain: entry.domain, name: entry.name)
            guard appliedKeys.contains(key.label) else { continue }
            do {
                if let original = entry.original {
                    try system.set(original.asValue, for: key)
                } else {
                    try system.remove(key)
                }
                rolledBack.append(key.label)
            } catch {
                log("dockmode rollback failed key=\(key.label)")
            }
        }
        return rolledBack
    }
}
