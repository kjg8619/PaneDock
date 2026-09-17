import Foundation

/// 화면에 보여줄 상태(기획서 §5). UI 문자열이 아니라 **값**으로 둔다.
///
/// - `tracked`  추적 중: 유효한 포커스와 경로를 확인했다
/// - `held`     유지 중: 바깥 앱이 최전면이 아니다. 마지막으로 확인한 대상을 그대로 표시한다
/// - `locked`   잠금: 사용자가 대상을 고정했다
/// - `pending`  확인 중: 아직 유효한 대상을 확인하지 못했다
/// - `error`    오류: 경로가 없거나 조회에 실패했다
public enum DockDisplayState: String, Codable, Sendable {
    case tracked
    case held
    case locked
    case pending
    case error
}

/// 실행 항목. UI가 아니라 **의도**로 다룬다.
public enum DockAction: String, Codable, Sendable, CaseIterable {
    case openFolder
    case copyPath
}

/// 실행 계획. 셸 명령 문자열을 만들지 않는다. URL 또는 원본 문자열만 돌려준다.
public enum DockActionPlan: Equatable, Sendable {
    case openFolder(URL)
    case copyPath(String)
    case reject(reason: String)

    public var rejectionReason: String? {
        if case .reject(let reason) = self { return reason }
        return nil
    }
}

/// 현재 표시 대상의 잠금. 잠긴 동안에는 새 후보로 바뀌지 않는다.
public struct DockLock: Equatable, Sendable {
    public private(set) var info: CurrentWorkInfo?

    public init(info: CurrentWorkInfo? = nil) {
        self.info = info
    }

    public var isLocked: Bool { info != nil }

    public mutating func lock(_ info: CurrentWorkInfo) {
        self.info = info
    }

    public mutating func unlock() {
        self.info = nil
    }
}

/// 화면 상태 한 묶음. 표시 문자열은 여기서 만들지 않고 값만 담는다.
public struct DockState: Equatable, Sendable {
    public var display: DockDisplayState
    /// 폴더 이름(마지막 경로 구성요소). 확인 전이면 "-".
    public var folderName: String
    public var fullPath: String?
    /// 직전에 표시하던 위치. "이전 위치"로만 쓴다.
    public var previousPath: String?
    public var paneID: String?
    public var hostFrontmost: Bool?
    public var observedAt: Date?
    /// 오류·안내 사유. 사용자에게 그대로 보여줄 수 있는 문장.
    public var detail: String?
    public var isLocked: Bool
    public var canOpenFolder: Bool
    public var canCopyPath: Bool
}

public enum DockStateBuilder {
    /// 표시 상태를 파생한다.
    ///
    /// 규칙:
    /// - 연결이 끊겼거나 조회에 실패하면 **오류**다. 마지막 경로를 유효한 것처럼 계속 보여주지 않는다.
    /// - 잠금이 걸려 있으면 잠긴 대상을 보여준다(새 후보로 바뀌지 않는다).
    /// - 경로가 유효하고 바깥 앱이 최전면이면 추적 중, 아니면 유지 중이다.
    /// - 아직 대상을 확인하지 못했으면 확인 중이다.
    public static func make(
        current: CurrentWorkInfo?,
        previous: CurrentWorkInfo?,
        connection: ConnectionStatus,
        failure: String?,
        lock: DockLock
    ) -> DockState {
        let active = lock.info ?? current
        let isLocked = lock.isLocked

        let display: DockDisplayState
        let detail: String?
        if connection != .connected {
            display = .error
            detail = failure ?? "연결을 확인할 수 없습니다"
        } else if isLocked, let active, active.pathStatus == .valid {
            display = .locked
            detail = nil
        } else if let active, active.pathStatus == .valid {
            display = active.focusStatus == .tracked ? .tracked : .held
            detail = nil
        } else if active == nil || active?.pathStatus == .pending {
            display = .pending
            detail = failure
        } else {
            display = .error
            detail = describe(active?.pathStatus) ?? "실행할 경로를 확인할 수 없습니다"
        }

        let path = active?.reportedCWD
        // 버튼 활성화는 **표시 상태와 일치**해야 한다. 오류·확인 중에는 실행할 대상을 확인하지 못한
        // 상태이므로 두 버튼을 모두 막는다(거부 사유는 detail 줄에 이미 표시된다).
        let actionable = (display == .tracked || display == .held || display == .locked)
        let hasPath = path?.isEmpty == false

        return DockState(
            display: display,
            folderName: folderName(of: path),
            fullPath: path,
            previousPath: previous?.reportedCWD,
            paneID: active?.identity.paneID,
            hostFrontmost: active?.hostFrontmost,
            observedAt: active?.observedAt,
            detail: detail,
            isLocked: isLocked,
            canOpenFolder: actionable && hasPath,
            canCopyPath: actionable && hasPath
        )
    }

    public static func folderName(of path: String?) -> String {
        guard let path, !path.isEmpty else { return "-" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func describe(_ status: PathStatus?) -> String? {
        switch status {
        case .missing: return "보고된 경로가 파일 시스템에 없습니다"
        case .unsupported: return "연동이 작업 경로를 제공하지 않았습니다"
        case .pending: return "경로를 확인하는 중입니다"
        case .valid, .none: return nil
        }
    }
}

public enum DockActionPlanner {
    /// 클릭 시점에 넘긴 값만 보고 실행 계획을 만든다.
    ///
    /// 이 함수는 상태를 읽지 않는다. 클릭 도중 도착한 갱신이 실행 대상을 바꾸지 못하게 하려면
    /// 호출자가 **클릭 순간의 값**을 넘겨야 한다.
    ///
    /// - 폴더 열기: 지금 이 순간 디렉터리인지 다시 확인한다. 아니면 거부한다.
    /// - 경로 복사: 경로가 비어 있지 않으면 된다(없는 경로라도 복사 자체는 안전하다).
    public static func plan(
        _ action: DockAction,
        for info: CurrentWorkInfo?,
        validator: PathValidating
    ) -> DockActionPlan {
        guard let path = info?.reportedCWD, !path.isEmpty else {
            return .reject(reason: "표시할 경로가 없습니다")
        }

        switch action {
        case .copyPath:
            return .copyPath(path)
        case .openFolder:
            guard validator.isDirectory(path) else {
                return .reject(reason: "폴더를 확인할 수 없습니다: \(path)")
            }
            return .openFolder(URL(fileURLWithPath: path))
        }
    }
}
