import Foundation

/// 앱이 시작할 때 할 일.
///
/// **컨트롤러 초기화와 저장된 모드 적용을 분리**하기 위한 결정값이다.
/// 화면·메뉴가 준비되기 전에 시스템 설정을 건드리지 않도록, 결정과 실행을 나눠 둔다.
public enum DockStartupDecision: Equatable, Sendable {
    /// 아무것도 하지 않는다(기본 Dock 그대로).
    case macDock(String)
    /// 저장된 선택·동의로 Custom을 적용한다.
    case applyCustom(suppression: Bool)
    /// 미완료·손상 기록이 있어 **먼저 복구**해야 한다(자동 적용하지 않는다).
    case recoverFirst(String)
    /// 지난 적용이 실패했으므로 자동 적용하지 않는다(사용자가 직접).
    case skipAfterFailure(String)
    /// 이번 버전에서 적용할 수 없는 모드.
    case unsupported(String)

    public var reason: String {
        switch self {
        case .macDock(let reason), .recoverFirst(let reason), .skipAfterFailure(let reason), .unsupported(let reason):
            return reason
        case .applyCustom(let suppression):
            return "저장된 Custom 모드 적용(억제 \(suppression ? "포함" : "없음"))"
        }
    }

    public var appliesCustom: Bool {
        if case .applyCustom = self { return true }
        return false
    }
}

public enum DockStartupPolicy {
    /// 저장된 설정과 복구 상태로 시작 동작을 정한다.
    ///
    /// 순서가 중요하다: **미완료 복구가 있으면 모드 선택보다 먼저** 그것을 처리해야 한다
    /// (그 파일이 사용자의 유일한 복구 수단이다).
    public static func decide(
        selectedMode: DockMode?,
        consent: String?,
        suppressionApproved: Bool,
        lastApplyFailedAt: String?,
        recovery: DockRecoveryLoad
    ) -> DockStartupDecision {
        // 1) 끝나지 않은 복구가 있으면 먼저 복구한다(손상 포함).
        switch recovery {
        case .unreadable(let reason):
            return .recoverFirst("복구 기록을 읽을 수 없습니다(\(reason))")
        case .record(let record) where record.hasPendingWork:
            return .recoverFirst("미완료 복구 기록 \(record.pendingKeyLabels.count)건")
        case .none, .noPath, .record:
            break
        }

        // 2) 모드를 고른 적이 없으면 Mac Dock(동의로 간주하지 않는다).
        guard let selected = selectedMode else {
            return .macDock("선택한 적 없음")
        }
        guard selected.isImplemented else {
            return .unsupported("\(selected.label)은 이번 버전에서 적용할 수 없습니다")
        }
        guard selected == .custom else {
            return .macDock("선택: \(selected.label)")
        }

        // 3) Custom: 동의가 있어야 하고, 지난 실패가 있으면 자동 적용하지 않는다.
        guard consent != nil else {
            return .macDock("Custom 동의 없음")
        }
        if let failedAt = lastApplyFailedAt {
            return .skipAfterFailure("지난 적용 실패(\(failedAt)) — 자동으로 다시 시도하지 않습니다")
        }
        return .applyCustom(suppression: suppressionApproved)
    }
}
