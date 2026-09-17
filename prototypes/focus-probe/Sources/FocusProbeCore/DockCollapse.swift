import Foundation

/// Dock 표시 모드.
///
/// **자동 접기는 화면 가장자리 자동 숨김이 아니다.** 화면 밖으로 밀거나 가장자리에서 다시 불러오는 방식이 아니라,
/// 지금 Dock이 있는 자리에 **작은 호출 손잡이만 남기고** 마우스가 닿으면 다시 펼친다.
public enum DockDisplayMode: String, Codable, Sendable, CaseIterable {
    case alwaysVisible
    case autoCollapse

    public var label: String {
        switch self {
        case .alwaysVisible: return "항상 표시"
        case .autoCollapse: return "자동 접기"
        }
    }

    /// 편집창에서 보여줄 설명. 두 방식의 차이를 분명히 말한다.
    public var summary: String {
        switch self {
        case .alwaysVisible: return "지금처럼 계속 보입니다."
        case .autoCollapse: return "쓰지 않을 때 이 자리에 작은 손잡이만 남습니다(화면 가장자리로 숨는 방식이 아닙니다)."
        }
    }
}

/// 접기 판단에 필요한 상태.
///
/// **키 입력 전체 감시·화면 읽기 없이** 값만으로 판단한다(마우스 위치는 우리 창의 추적 영역에서 온다).
public struct DockCollapseContext: Equatable, Sendable {
    public var mode: DockDisplayMode
    public var isCollapsed: Bool
    /// 마우스가 Dock 또는 호출 손잡이 위에 있는가.
    public var mouseInsideDock: Bool
    /// 마우스 버튼을 누르고 있는가(창 드래그 포함).
    public var isMouseButtonDown: Bool
    /// 단축키·메뉴로 호출해 키보드 선택을 진행 중인가.
    public var isInvoked: Bool
    public var isDetailsVisible: Bool
    public var isEditorOpen: Bool
    /// 메뉴·파일 선택 대화상자 같은 모달 UI가 떠 있는가.
    public var isModalOpen: Bool
    /// 사용자가 **명시적으로 숨긴** 상태인가(자동 접기와 구분한다).
    public var isUserHidden: Bool

    public init(
        mode: DockDisplayMode = .alwaysVisible,
        isCollapsed: Bool = false,
        mouseInsideDock: Bool = false,
        isMouseButtonDown: Bool = false,
        isInvoked: Bool = false,
        isDetailsVisible: Bool = false,
        isEditorOpen: Bool = false,
        isModalOpen: Bool = false,
        isUserHidden: Bool = false
    ) {
        self.mode = mode
        self.isCollapsed = isCollapsed
        self.mouseInsideDock = mouseInsideDock
        self.isMouseButtonDown = isMouseButtonDown
        self.isInvoked = isInvoked
        self.isDetailsVisible = isDetailsVisible
        self.isEditorOpen = isEditorOpen
        self.isModalOpen = isModalOpen
        self.isUserHidden = isUserHidden
    }
}

/// 언제 접고 언제 펼치는가. **화면 없이 값으로 판단**하므로 자체 검사로 고정할 수 있다.
public enum DockCollapsePolicy {
    /// 마우스가 떠난 뒤 이 시간 동안 상호작용이 없으면 접는다(첫 기준).
    public static let delay: TimeInterval = 1.0

    /// 지금 접으면 안 되는 이유. nil이면 접어도 된다.
    public static func collapseBlock(_ context: DockCollapseContext) -> String? {
        if context.mode != .autoCollapse { return "mode=\(context.mode.rawValue)" }
        if context.isCollapsed { return "already-collapsed" }
        if context.isUserHidden { return "user-hidden" }
        if context.mouseInsideDock { return "mouse-inside" }
        if context.isMouseButtonDown { return "mouse-down" }
        if context.isInvoked { return "keyboard-session" }
        if context.isDetailsVisible { return "details-open" }
        if context.isEditorOpen { return "editor-open" }
        if context.isModalOpen { return "modal-open" }
        return nil
    }

    public static func shouldCollapse(_ context: DockCollapseContext) -> Bool {
        collapseBlock(context) == nil
    }

    /// 손잡이에 마우스가 닿았을 때 펼칠지.
    ///
    /// **입력 포커스를 빼앗지 않고, 호출(키보드 선택) 세션도 시작하지 않는다** —
    /// hover만으로는 고정 세션이 열리지 않는다.
    public static func shouldExpandForHover(_ context: DockCollapseContext) -> Bool {
        context.mode == .autoCollapse && context.isCollapsed && !context.isUserHidden
    }

    /// 접힘/펼침 판단을 잠시 뒤에 다시 해야 하는가(마우스를 누르고 있는 동안만).
    /// 상호작용이 끝나면 조건을 다시 판단하기 위한 것이다.
    public static func needsRecheckAfterBlock(_ reason: String?) -> Bool {
        reason == "mouse-down"
    }
}

/// 늦게 도착한 타이머가 **새로 펼친 Dock을 접지 못하게** 세대 토큰으로 막는다.
///
/// 예약할 때 받은 토큰이 그대로 최신일 때만 실행한다. 취소·재예약이 있으면 토큰이 달라져 무시된다.
public final class CollapseScheduler {
    private var generation = 0

    public init() {}

    /// 새 예약을 시작한다. 이 토큰이 최신일 때만 실행해야 한다.
    public func nextToken() -> Int {
        generation += 1
        return generation
    }

    /// 진행 중인 예약을 무효로 만든다.
    public func cancel() {
        generation += 1
    }

    /// 이 토큰이 아직 유효한가.
    public func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}
