import Foundation

/// PaneDock 사용 모드.
///
/// - `macDock`: 기본 macOS Dock을 **원래 설정 그대로** 두고 PaneDock 커스텀 화면은 띄우지 않는다.
/// - `custom`: **사용자 동의 후** 기본 Dock을 숨기고 PaneDock을 화면 하단 주 Dock으로 쓴다(해제·종료 시 복원).
/// - `both`: 기본 Dock 유지 + 호출형 측면 패널 — **V20.2(미구현)**. 정책·확장 지점만 두고 선택지로 제공하지 않는다.
public enum DockMode: String, Codable, Sendable, CaseIterable {
    case macDock
    case custom
    case both

    public var label: String {
        switch self {
        case .macDock: return "Mac Dock"
        case .custom: return "Custom Dock"
        case .both: return "Both (V20.2)"
        }
    }

    public var summary: String {
        switch self {
        case .macDock: return "기본 Dock을 그대로 두고 PaneDock 화면은 띄우지 않습니다."
        case .custom: return "동의 후 기본 Dock을 숨기고 PaneDock을 화면 하단에 둡니다. 해제·종료 시 되돌립니다."
        case .both: return "기본 Dock을 두고 PaneDock을 호출형 측면 패널로 씁니다 — 다음 단계(V20.2)입니다."
        }
    }

    /// 이번에 실제로 적용할 수 있는 모드인가. **미구현 모드를 작동하는 선택지로 제공하지 않는다.**
    public var isImplemented: Bool { self != .both }
}

/// 시스템 Dock 설정 키 하나.
public struct DockPreferenceKey: Hashable, Sendable {
    public var domain: String
    public var name: String

    public init(domain: String, name: String) {
        self.domain = domain
        self.name = name
    }

    public var label: String { "\(domain):\(name)" }
}

/// 기록한 **원래 값**. 값이 아니라 **자료형·존재 여부까지** 남겨 정확히 되돌린다.
public enum DockPreferenceValue: Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)

    public var typeName: String {
        switch self {
        case .bool: return "bool"
        case .integer: return "int"
        case .double: return "double"
        case .string: return "string"
        }
    }

    public var text: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        }
    }
}

/// 적용 전에 남기는 스냅숏. 값이 `nil`이면 **원래 없던 키**다(복원 시 삭제).
public struct DockPreferenceSnapshot: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: DockPreferenceKey
        public var value: DockPreferenceValue?

        public init(key: DockPreferenceKey, value: DockPreferenceValue?) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func original(for key: DockPreferenceKey) -> DockPreferenceValue?? {
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        return entry.value
    }
}

/// 시스템 Dock 제어 경계.
///
/// 실제 구현은 기본 Dock 설정을 읽고 쓴다. **자동 검사는 이 프로토콜을 대체 구현으로 바꿔** 실제 시스템을 건드리지 않는다.
public protocol DockSystemControl: AnyObject {
    func snapshot(_ keys: [DockPreferenceKey]) -> DockPreferenceSnapshot
    func currentValue(for key: DockPreferenceKey) -> DockPreferenceValue?
    func set(_ value: DockPreferenceValue, for key: DockPreferenceKey) throws
    func remove(_ key: DockPreferenceKey) throws
    /// 설정 반영을 위해 Dock을 **한 번** 다시 시작한다(반복 강제 종료 금지).
    func restartDock() throws
}

/// 적용할 변경 하나(키 + 값).
public struct DockChange: Equatable, Sendable {
    public var key: DockPreferenceKey
    public var value: DockPreferenceValue

    public init(_ key: DockPreferenceKey, _ value: DockPreferenceValue) {
        self.key = key
        self.value = value
    }
}

/// Custom 적용 계획.
public struct DockModePlan: Equatable, Sendable {
    /// 숨김에 필요한 **공식 설정**(System Settings › 자동으로 Dock 가리기).
    public var hideKeys: [DockChange]
    /// 재등장 억제에 쓰는 **문서화되지 않은 설정**. 승인받은 경우에만 적용한다.
    public var suppressionKeys: [DockChange]

    public init(hideKeys: [DockChange], suppressionKeys: [DockChange]) {
        self.hideKeys = hideKeys
        self.suppressionKeys = suppressionKeys
    }

    /// 기본 계획(도메인 `com.apple.dock`).
    public static let systemDefault = DockModePlan(
        hideKeys: [DockChange(DockPreferenceKey(domain: "com.apple.dock", name: "autohide"), .bool(true))],
        // 문서화되지 않은 값들 — 승인 없이는 쓰지 않는다.
        suppressionKeys: [
            DockChange(DockPreferenceKey(domain: "com.apple.dock", name: "autohide-delay"), .double(1000)),
            DockChange(DockPreferenceKey(domain: "com.apple.dock", name: "autohide-time-modifier"), .double(0)),
        ]
    )

    public var allKeys: [DockPreferenceKey] { hideKeys.map(\.key) + suppressionKeys.map(\.key) }

    /// 실제로 적용할 변경 목록(억제 승인 여부에 따라 달라진다).
    public func changes(includeSuppression: Bool) -> [DockChange] {
        includeSuppression ? hideKeys + suppressionKeys : hideKeys
    }
}

/// 모드 적용 상태. **선택한 모드와 별개로** 실제 적용된 것만 담는다.
public enum DockAppliedState: Equatable, Sendable {
    case none
    case custom(appliedAt: Date, suppression: Bool)

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .none: return "적용 안 됨(기본 Dock 사용)"
        case .custom(_, let suppression): return suppression ? "Custom 적용 중(억제 포함)" : "Custom 적용 중(자동 숨김)"
        }
    }
}

public enum DockModeError: Error, Equatable {
    case notConsented
    case unsupportedMode(DockMode)
    case busy
    /// 복구 정보를 기록하지 못했다 — **시스템 설정을 바꾸지 않는다.**
    case recoveryRecordUnavailable(String)
    /// 복구 기록 파일이 손상돼 읽을 수 없다(**지우지 않는다** — 수동 확인 경로를 남긴다).
    case restoreRecordUnreadable(String)
    /// 복구 기록이 없는데 원래 값도 알 수 없다.
    case restoreRecordMissing
    /// 다른 인스턴스가 모드를 적용 중이다.
    case otherInstanceActive
    case applyFailed(step: String, reason: String)
    /// 되돌리기까지 실패했다(복구 기록은 남겨 둔다).
    case rollbackFailed(String)

    public var message: String {
        switch self {
        case .notConsented: return "동의가 없어 Custom 모드를 적용하지 않았습니다."
        case .unsupportedMode(let mode): return "\(mode.label)은 이번 버전에서 적용할 수 없습니다(V20.2 예정)."
        case .busy: return "이미 전환 작업이 진행 중입니다."
        case .recoveryRecordUnavailable(let reason): return "복구 정보를 기록하지 못해 시스템 설정을 바꾸지 않았습니다: \(reason)"
        case .otherInstanceActive: return "다른 PaneDock 인스턴스가 사용 모드를 적용 중입니다."
        case .restoreRecordUnreadable(let reason): return "복구 기록 파일을 읽을 수 없습니다(\(reason)) — 지우지 않고 남겨 두었습니다. 파일을 확인한 뒤 직접 되돌려 주세요."
        case .restoreRecordMissing: return "복구 기록이 없어 원래 값을 알 수 없습니다."
        case .applyFailed(let step, let reason): return "\(step) 단계에서 실패했습니다: \(reason)"
        case .rollbackFailed(let reason): return "되돌리기에 실패했습니다: \(reason) — 복구 기록을 남겼습니다."
        }
    }
}
