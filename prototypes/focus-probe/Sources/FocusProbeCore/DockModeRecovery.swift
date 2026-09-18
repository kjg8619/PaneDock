import Foundation

// MARK: - 값 비교·변환 (실제 설정 경계)

public extension DockPreferenceValue {
    /// 자료형이 달라도 **수치가 같으면 같은 값**으로 본다.
    ///
    /// macOS가 정수/실수를 같은 키에서 바꿔 읽는 경우가 있다(예: `autohide-delay = 1000.0`을
    /// 정수로 돌려주는 구현). 자료형만 비교하면 **적용 확인·사용자 변경 감지·되돌리기 확인**이
    /// 모두 어긋난다. 그래서 비교는 이 함수 하나로 통일한다.
    func matches(_ other: DockPreferenceValue) -> Bool {
        switch (self, other) {
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.integer(let lhs), .integer(let rhs)): return lhs == rhs
        case (.double(let lhs), .double(let rhs)): return lhs == rhs
        case (.integer(let lhs), .double(let rhs)): return Double(lhs) == rhs
        case (.double(let lhs), .integer(let rhs)): return lhs == Double(rhs)
        default: return false
        }
    }

    /// CFNumber에서 읽은 값을 **부동소수 여부까지 살려** 옮긴다.
    ///
    /// `isFloat`를 무시하고 정수로 바꾸면 `.double(1000)`이 `.integer(1000)`이 되어
    /// 원래 자료형을 잃는다(되돌릴 때 정수를 쓰게 된다).
    static func fromNumber(_ value: Double, isFloat: Bool) -> DockPreferenceValue {
        if !isFloat, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return .integer(Int(value))
        }
        return .double(value)
    }
}

// MARK: - 복구 기록

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
        /// 남겨 둔 이유(`userChanged`·`keyRemoved`·`restoreFailed`) — 화면·명령줄에서 그대로 보여준다.
        public var skipReason: String?

        public init(
            domain: String,
            name: String,
            original: StoredValue?,
            applied: StoredValue,
            skippedByUserChange: Bool = false,
            skipReason: String? = nil
        ) {
            self.domain = domain
            self.name = name
            self.original = original
            self.applied = applied
            self.skippedByUserChange = skippedByUserChange
            self.skipReason = skipReason
        }

        public var keyLabel: String { "\(domain):\(name)" }
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

        /// 기록에 남은 **자료형**(되돌릴 때 같은 자료형으로 쓴다).
        public var typeName: String {
            switch self {
            case .bool: return "bool"
            case .integer: return "int"
            case .double: return "double"
            case .string: return "string"
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

    /// 이 기록을 만든 **작업 하나**의 식별자. 진행 갱신과 새 기록 생성을 가르는 기준이다.
    public var operationID: String
    public var mode: String
    public var appliedAt: Date
    public var updatedAt: Date
    public var suppression: Bool
    public var entries: [Entry]
    /// 이 기록을 만든 프로세스(다른 인스턴스 확인용).
    public var ownerPID: Int32
    /// 기록을 만든 **부팅 세션**(재부팅 뒤의 기록을 구분한다).
    public var bootID: String
    /// 값은 되돌렸지만 Dock 재시작이 아직 안 끝났는가(다음 시도에서 재시작만 다시 한다).
    public var restartPending: Bool

    public init(
        operationID: String,
        mode: String,
        appliedAt: Date,
        updatedAt: Date? = nil,
        suppression: Bool,
        entries: [Entry],
        ownerPID: Int32,
        bootID: String,
        restartPending: Bool = false
    ) {
        self.operationID = operationID
        self.mode = mode
        self.appliedAt = appliedAt
        self.updatedAt = updatedAt ?? appliedAt
        self.suppression = suppression
        self.entries = entries
        self.ownerPID = ownerPID
        self.bootID = bootID
        self.restartPending = restartPending
    }

    private enum CodingKeys: String, CodingKey {
        case operationID, mode, appliedAt, updatedAt, suppression, entries, ownerPID, bootID, restartPending
    }

    /// 관대한 디코더: 이전 형식(`operationID`·`updatedAt`·`bootID` 없음)도 읽는다.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        appliedAt = try container.decode(Date.self, forKey: .appliedAt)
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? appliedAt
        suppression = (try? container.decode(Bool.self, forKey: .suppression)) ?? false
        entries = (try? container.decode([Entry].self, forKey: .entries)) ?? []
        ownerPID = (try? container.decode(Int32.self, forKey: .ownerPID)) ?? 0
        bootID = (try? container.decode(String.self, forKey: .bootID)) ?? ""
        // 없던 필드는 **빈 작업 ID**로 둔다(새 작업으로 오인해 덮어쓰지 않도록 `create`가 거부한다).
        operationID = (try? container.decode(String.self, forKey: .operationID)) ?? ""
        restartPending = (try? container.decode(Bool.self, forKey: .restartPending)) ?? false
    }

    /// 아직 복원하지 않은 키가 있는가.
    public var hasUnrestoredKeys: Bool { !entries.isEmpty }

    public var unrestoredKeyLabels: [String] { entries.map(\.keyLabel) }
}

/// 복구 기록 읽기 결과. **손상을 '기록 없음'으로 뭉개지 않는다**(복구 수단이 조용히 사라지면 안 된다).
public enum DockRecoveryLoad: Equatable, Sendable {
    case none
    case record(DockRecoveryRecord)
    /// 파일은 있는데 읽을 수 없다(손상·권한·잘못된 JSON). 파일은 **지우지 않는다**.
    case unreadable(reason: String)
    case noPath

    public var record: DockRecoveryRecord? {
        if case .record(let record) = self { return record }
        return nil
    }

    public var summary: String {
        switch self {
        case .none: return "복구 기록 없음"
        case .record(let record): return "미복원 기록 \(record.entries.count)키"
        case .unreadable(let reason): return "복구 기록을 읽을 수 없음(\(reason))"
        case .noPath: return "복구 기록 경로 없음"
        }
    }
}

/// 기록 쓰기 결과. **실패를 Bool 하나로 뭉개지 않는다** — 왜 못 썼는지에 따라 해야 할 일이 다르다.
public enum DockRecoveryWrite: Equatable, Sendable {
    case written
    /// 다른 작업의 미복원 기록이 있다 — **새 적용을 거부**한다(원본을 잃지 않게).
    case refusedPendingRestore([String])
    /// 기존 기록을 읽을 수 없다 — **원본을 보존**하고 거부한다.
    case refusedUnreadable(String)
    case failed(String)
    case noPath

    public var isWritten: Bool { self == .written }

    public var failureReason: String? {
        switch self {
        case .written: return nil
        case .refusedPendingRestore(let keys): return "미복원 기록이 있습니다(\(keys.joined(separator: ",")))"
        case .refusedUnreadable(let reason): return "복구 기록을 읽을 수 없습니다(\(reason))"
        case .failed(let reason): return reason
        case .noPath: return "복구 기록 경로가 없습니다"
        }
    }
}

/// 기록 삭제 결과. **삭제 실패를 무시하지 않는다.**
public enum DockRecoveryClear: Equatable, Sendable {
    case removed
    case absent
    /// 다른 작업의 기록이라 지우지 않았다.
    case notOwner(String)
    case failed(String)
    case noPath

    public var isClean: Bool { self == .removed || self == .absent }

    public var failureReason: String? {
        switch self {
        case .removed, .absent: return nil
        case .notOwner(let owner): return "다른 작업(\(owner))의 기록이라 지우지 않았습니다"
        case .failed(let reason): return reason
        case .noPath: return "복구 기록 경로가 없습니다"
        }
    }
}

/// 복구 기록을 파일로 보관한다(경로 주입 가능 — 검사는 임시 경로를 쓴다).
public struct DockRecoveryStore: Sendable {
    public var url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func load() -> DockRecoveryRecord? { loadResult().record }

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

    /// **새 작업**의 기록을 만든다.
    ///
    /// - 다른 작업의 미복원 기록이 있으면 거부한다(그 기록이 사용자의 유일한 복구 수단이다).
    /// - 손상된 기록이 있으면 거부하고 **원본을 보존**한다.
    public func create(_ record: DockRecoveryRecord) -> DockRecoveryWrite {
        guard url != nil else { return .noPath }
        switch loadResult() {
        case .unreadable(let reason):
            return .refusedUnreadable(reason)
        case .record(let existing) where existing.hasUnrestoredKeys:
            return .refusedPendingRestore(existing.unrestoredKeyLabels)
        case .none, .noPath, .record:
            return write(record)
        }
    }

    /// **같은 작업**(operationID)의 진행 갱신. 다른 작업의 기록은 건드리지 않는다.
    public func update(_ record: DockRecoveryRecord) -> DockRecoveryWrite {
        guard url != nil else { return .noPath }
        switch loadResult() {
        case .unreadable(let reason):
            return .refusedUnreadable(reason)
        case .record(let existing):
            if existing.operationID != record.operationID {
                return .refusedPendingRestore(existing.unrestoredKeyLabels)
            }
            return write(record)
        case .none, .noPath:
            // 파일이 사라졌다(외부 삭제). 같은 작업의 진행 갱신이므로 다시 만든다.
            return write(record)
        }
    }

    /// **복원을 확인한 뒤에만** 기록을 지운다. 같은 작업의 기록만 지운다.
    public func clear(operationID: String) -> DockRecoveryClear {
        guard let url else { return .noPath }
        switch loadResult() {
        case .none:
            return .absent
        case .unreadable(let reason):
            // 손상된 기록은 지우지 않는다(무엇이었는지 확인할 수 있어야 한다).
            return .failed("복구 기록을 읽을 수 없습니다(\(reason)) — 지우지 않았습니다")
        case .record(let existing):
            guard existing.operationID == operationID else {
                return .notOwner(existing.operationID.isEmpty ? "(알 수 없음)" : existing.operationID)
            }
            do {
                try FileManager.default.removeItem(at: url)
                return .removed
            } catch {
                return .failed((error as NSError).localizedDescription)
            }
        case .noPath:
            return .noPath
        }
    }

    private func write(_ record: DockRecoveryRecord) -> DockRecoveryWrite {
        guard let url else { return .noPath }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            return .failed("기록을 만들지 못했습니다: \((error as NSError).localizedDescription)")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }
}

// MARK: - 잠금 (증거 기반)

/// 잠금 소유자 정보. **PID 하나로 소유권을 단정하지 않기 위해** 부팅 세션·작업 ID·시각을 함께 남긴다.
public struct DockLockInfo: Codable, Equatable, Sendable {
    public var ownerPID: Int32
    public var operationID: String
    public var purpose: String
    public var bootID: String
    public var recordedAt: Date

    public init(ownerPID: Int32, operationID: String, purpose: String, bootID: String, recordedAt: Date) {
        self.ownerPID = ownerPID
        self.operationID = operationID
        self.purpose = purpose
        self.bootID = bootID
        self.recordedAt = recordedAt
    }
}

public enum DockLockResult: Equatable, Sendable {
    case acquired
    /// 살아 있는 다른 인스턴스가 잡고 있다 — **지우지 않는다**.
    case heldByOther(DockLockInfo)
    /// 증거가 있는 stale 잠금을 이어받았다(원본은 사본으로 보존).
    case tookOverStale(DockLockInfo, preservedPath: String?)
    case unavailable(String)
    /// 경로가 없다 — 잠금 없이 진행한다(검사용).
    case noPath
}

public enum DockLockRelease: Equatable, Sendable {
    case removed
    case absent
    /// 다른 작업이 잡고 있어 지우지 않았다.
    case notOwner
    case failed(String)
    case noPath
}

/// 중복 인스턴스가 서로 설정을 바꾸지 못하게 하는 잠금.
///
/// **stale 판정은 증거로만 한다**: 파일 존재만으로는 아무것도 단정하지 않고,
/// 살아 있는 소유자의 잠금은 절대 지우지 않는다. 이어받을 때는 원본을 사본으로 남긴다.
public struct DockModeLock: Sendable {
    public var url: URL?

    public init(url: URL?) {
        self.url = url
    }

    public func current() -> DockLockInfo? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DockLockInfo.self, from: data)
    }

    /// stale 근거를 모은다. 셋 중 하나라도 해당하면 stale이고, 그 이유를 함께 돌려준다.
    public func stalenessReason(
        _ info: DockLockInfo,
        now: Date,
        lease: TimeInterval,
        bootID: String,
        isProcessAlive: Bool
    ) -> String? {
        if !info.bootID.isEmpty, info.bootID != bootID {
            return "다른 부팅 세션의 잠금"
        }
        if !isProcessAlive {
            return "소유 프로세스(\(info.ownerPID))가 없음"
        }
        let age = now.timeIntervalSince(info.recordedAt)
        if age > lease {
            return "작업 시각이 \(Int(age))초 지남(리스 \(Int(lease))초 초과)"
        }
        return nil
    }

    public func acquire(
        _ info: DockLockInfo,
        lease: TimeInterval = 600,
        isProcessAlive: (Int32) -> Bool = DockModeLock.isAlive
    ) -> DockLockResult {
        guard let url else { return .noPath }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .unavailable((error as NSError).localizedDescription)
        }

        var preserved: String?
        if let existing = current() {
            // 같은 작업의 재진입은 그대로 진행한다(리스만 갱신).
            if existing.operationID == info.operationID {
                return write(info) ? .acquired : .unavailable("잠금을 갱신하지 못했습니다")
            }
            let alive = isProcessAlive(existing.ownerPID)
            guard let reason = stalenessReason(existing, now: info.recordedAt, lease: lease, bootID: info.bootID, isProcessAlive: alive) else {
                return .heldByOther(existing)
            }
            // 이어받는다. 원본은 **지우지 않고 사본으로 남긴다**(무엇이 있었는지 확인 가능).
            let stamp = ISO8601DateFormatter().string(from: info.recordedAt).replacingOccurrences(of: ":", with: "")
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).stale-\(stamp)")
            if let data = try? Data(contentsOf: url) {
                try? data.write(to: backup, options: .atomic)
                preserved = backup.path
            }
            guard write(info) else { return .unavailable("stale 잠금을 이어받지 못했습니다") }
            return .tookOverStale(existing, preservedPath: preserved == nil ? nil : "\(preserved!) (\(reason))")
        }

        guard write(info) else { return .unavailable("잠금 파일을 만들지 못했습니다") }
        return .acquired
    }

    /// 같은 작업의 리스를 갱신한다(긴 적용·복원이 스스로 stale이 되지 않게).
    @discardableResult
    public func refresh(operationID: String, now: Date) -> Bool {
        guard var info = current(), info.operationID == operationID else { return false }
        info.recordedAt = now
        return write(info)
    }

    /// 같은 작업의 잠금만 푼다.
    public func release(operationID: String) -> DockLockRelease {
        guard let url else { return .noPath }
        guard let info = current() else { return .absent }
        guard info.operationID == operationID else { return .notOwner }
        do {
            try FileManager.default.removeItem(at: url)
            return .removed
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    private func write(_ info: DockLockInfo) -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(info) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 프로세스 생존 확인(PID 재사용은 부팅 세션·리스로 함께 판단한다).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

// MARK: - 결과

/// 복원 결과 종류. **부분 복원과 실패를 성공으로 뭉개지 않는다.**
public enum DockRestoreKind: String, Equatable, Sendable {
    case nothingToDo
    case complete
    case partial
    case failed

    public var label: String {
        switch self {
        case .nothingToDo: return "되돌릴 것 없음"
        case .complete: return "완전 복원"
        case .partial: return "부분 복원"
        case .failed: return "복원 실패"
        }
    }
}

/// 키 하나의 복원 처분.
public enum DockRestoreDisposition: String, Equatable, Sendable {
    /// 원래 값으로 되돌리고 **확인까지 했다**.
    case restored
    /// 이미 원래 값이었다(할 일 없음).
    case alreadyOriginal
    /// 사용자가 실행 중 바꿔서 건드리지 않았다.
    case userChanged
    /// 원래 있던 키가 사라져 있다(사용자 삭제로 보고 만들지 않는다).
    case keyRemoved
    /// 되돌리기·확인 실패(기록에 남긴다).
    case failed

    public var label: String {
        switch self {
        case .restored: return "복원"
        case .alreadyOriginal: return "이미 원래 값"
        case .userChanged: return "사용자 변경"
        case .keyRemoved: return "키 삭제됨"
        case .failed: return "복원 실패"
        }
    }

    /// 기록에 남겨 두어야 하는 처분인가(다음 복구 시도에서 다시 본다).
    public var leavesRecordEntry: Bool {
        switch self {
        case .restored, .alreadyOriginal: return false
        case .userChanged, .keyRemoved, .failed: return true
        }
    }
}

public struct DockRestoreEntryResult: Equatable, Sendable {
    public var key: String
    public var disposition: DockRestoreDisposition
    public var detail: String

    public init(key: String, disposition: DockRestoreDisposition, detail: String = "") {
        self.key = key
        self.disposition = disposition
        self.detail = detail
    }
}

/// 복원 결과. 화면·명령줄이 **같은 값**을 쓴다.
public struct DockRestoreOutcome: Equatable, Sendable {
    public var kind: DockRestoreKind
    public var entries: [DockRestoreEntryResult]
    public var recordLeft: Bool
    public var restartPerformed: Bool
    public var notes: [String]

    public init(
        kind: DockRestoreKind,
        entries: [DockRestoreEntryResult] = [],
        recordLeft: Bool = false,
        restartPerformed: Bool = false,
        notes: [String] = []
    ) {
        self.kind = kind
        self.entries = entries
        self.recordLeft = recordLeft
        self.restartPerformed = restartPerformed
        self.notes = notes
    }

    public func count(_ disposition: DockRestoreDisposition) -> Int {
        entries.filter { $0.disposition == disposition }.count
    }

    /// 명령줄 한 줄 요약(결과 종류가 앞에 온다).
    public var summaryLine: String {
        "dock restore: \(kind.rawValue) restored=\(count(.restored)) already=\(count(.alreadyOriginal)) "
            + "userChanged=\(count(.userChanged)) removed=\(count(.keyRemoved)) failed=\(count(.failed)) "
            + "left=\(recordLeft) restart=\(restartPerformed)"
            + (notes.isEmpty ? "" : " notes=\(notes.joined(separator: " | "))")
    }

    /// 화면 안내 문구. **부분·실패를 '복원했습니다'로 말하지 않는다.**
    public var userMessage: String {
        switch kind {
        case .nothingToDo:
            return "되돌릴 Dock 설정이 없습니다(이미 기본 Dock 상태)."
        case .complete:
            return "기본 Dock 설정을 복원했습니다."
        case .partial:
            var parts: [String] = []
            if count(.restored) > 0 {
                parts.append("일부만 복원했습니다 — 복원 \(count(.restored))키")
            } else {
                parts.append("되돌리지 않은 키가 남아 있습니다")
            }
            if count(.userChanged) > 0 { parts.append("사용자 변경 \(count(.userChanged))키") }
            if count(.keyRemoved) > 0 { parts.append("사용자가 지운 키 \(count(.keyRemoved))개") }
            if count(.failed) > 0 { parts.append("실패 \(count(.failed))키") }
            if recordLeft { parts.append("기록을 남겨 두었습니다.") }
            return parts.joined(separator: " · ")
        case .failed:
            return "Dock 설정을 복원하지 못했습니다."
        }
    }
}

/// 적용 결과(검사·로그용).
public struct DockModeOutcome: Equatable, Sendable {
    public var applied: DockAppliedState
    public var changedKeys: [String]
    public var rolledBackKeys: [String]
    public var rollbackFailedKeys: [String]
    public var skippedByUserChange: [String]
    public var recoveryRecordLeft: Bool
    public var lockNote: String?
    public var notes: [String]

    public init(
        applied: DockAppliedState,
        changedKeys: [String],
        rolledBackKeys: [String] = [],
        rollbackFailedKeys: [String] = [],
        skippedByUserChange: [String] = [],
        recoveryRecordLeft: Bool = false,
        lockNote: String? = nil,
        notes: [String] = []
    ) {
        self.applied = applied
        self.changedKeys = changedKeys
        self.rolledBackKeys = rolledBackKeys
        self.rollbackFailedKeys = rollbackFailedKeys
        self.skippedByUserChange = skippedByUserChange
        self.recoveryRecordLeft = recoveryRecordLeft
        self.lockNote = lockNote
        self.notes = notes
    }
}

/// 부팅 세션 식별자(재부팅 구분). 시각을 되돌려도 값이 달라진다.
public enum DockBootID {
    public static func current(now: Date = Date()) -> String {
        let boot = now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        return ISO8601DateFormatter().string(from: boot)
    }
}

public enum DockModeError: Error, Equatable {
    case notConsented
    case unsupportedMode(DockMode)
    case busy
    /// 복구 정보를 기록하지 못했다 — **시스템 설정을 바꾸지 않는다.**
    case recoveryRecordUnavailable(String)
    /// 다른 작업의 미복원 기록이 있다 — **새 적용을 거부한다**(그 기록이 복구 수단이다).
    case recoveryRecordPending(String)
    /// 복구 기록 파일이 손상돼 읽을 수 없다(**지우지 않는다** — 수동 확인 경로를 남긴다).
    case restoreRecordUnreadable(String)
    /// 복구 기록이 없는데 원래 값도 알 수 없다.
    case restoreRecordMissing
    /// 다른 인스턴스가 모드를 적용·복원 중이다.
    case otherInstanceActive(String)
    case lockUnavailable(String)
    case applyFailed(step: String, reason: String)
    /// 되돌리기까지 실패했다(복구 기록은 남겨 둔다).
    case rollbackFailed(String)
    /// 기록 저장·갱신·삭제가 실패했다(무시하지 않고 알린다).
    case recoveryWriteFailed(String)

    public var message: String {
        switch self {
        case .notConsented: return "동의가 없어 Custom 모드를 적용하지 않았습니다."
        case .unsupportedMode(let mode): return "\(mode.label)은 이번 버전에서 적용할 수 없습니다(V20.2 예정)."
        case .busy: return "이미 전환 작업이 진행 중입니다."
        case .recoveryRecordUnavailable(let reason): return "복구 정보를 기록하지 못해 시스템 설정을 바꾸지 않았습니다: \(reason)"
        case .recoveryRecordPending(let reason): return "미복원 기록이 있어 새 적용을 하지 않았습니다: \(reason)"
        case .otherInstanceActive(let detail): return "다른 PaneDock 인스턴스가 사용 모드를 적용·복원 중입니다. \(detail)"
        case .lockUnavailable(let reason): return "잠금을 잡지 못해 작업을 시작하지 않았습니다: \(reason)"
        case .restoreRecordUnreadable(let reason): return "복구 기록 파일을 읽을 수 없습니다(\(reason)) — 지우지 않고 남겨 두었습니다. 파일을 확인한 뒤 직접 되돌려 주세요."
        case .restoreRecordMissing: return "복구 기록이 없어 원래 값을 알 수 없습니다."
        case .applyFailed(let step, let reason): return "\(step) 단계에서 실패했습니다: \(reason)"
        case .rollbackFailed(let reason): return "되돌리기에 실패했습니다: \(reason) — 복구 기록을 남겼습니다."
        case .recoveryWriteFailed(let reason): return "복구 기록을 다루지 못했습니다: \(reason)"
        }
    }
}
