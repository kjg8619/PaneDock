import Foundation

/// 가로형 Dock 바의 **배치 계산만** 담당한다. 그리기는 UI가 한다.
///
/// 여기 두는 이유: 항목이 많아질 때 무엇을 인라인으로 보여주고 무엇을 더보기로 보낼지,
/// 창이 화면을 넘지 않는지는 **규칙**이라 검사로 고정할 수 있어야 하기 때문이다.
/// 실제 화면 측정은 UI가 하고, 이 계산은 숫자만 받는다.
public enum DockBarLayout {
    /// 바 높이. 첫 시안은 64~80pt 범위로 잡고 가독성·클릭 영역을 보고 조정한다.
    public static let barHeight: CGFloat = 76
    /// 상세 보기 높이(열렸을 때 바 위로 펼쳐진다).
    public static let detailsHeight: CGFloat = 300
    /// 바 최소 너비. 항목이 없어도 주요 조작이 뭉개지지 않게 한다.
    public static let minimumBarWidth: CGFloat = 460

    /// 자동 접기 상태에서 남기는 **호출 손잡이** 크기.
    /// 화면 가장자리로 숨기는 방식이 아니라, 지금 위치에 작게 남아 마우스를 받는 영역이다.
    public static let handleWidth: CGFloat = 168
    public static let handleHeight: CGFloat = 30
    /// 바 최대 너비. 이보다 넓어지면 화면을 넘지 않도록 줄이고, 넘치는 링크는 더보기로 보낸다.
    public static let maximumBarWidth: CGFloat = 1_100
    /// 화면 가장자리에서 남길 여백(양쪽 합계).
    public static let screenMargin: CGFloat = 48
    /// 상태 배지·가짜 표시·아이콘 버튼·구분선·여백이 차지하는 **고정 영역**의 대략 너비.
    ///
    /// V15에서 항목 칩이 늘고 가짜 모드 표시가 바에 들어오면서 이 값이 커졌다.
    /// 실제보다 작게 잡으면 이름·배지가 압축돼 글자가 사라진다(V14·V15에서 스크린샷으로 확인).
    public static let fixedWidth: CGFloat = 448
    /// 링크 칩 하나의 대략 너비(아이콘 + 짧은 이름).
    ///
    /// **보수적으로 잡는다.** 이보다 좁게 잡으면 이름이 긴 칩이 압축돼 라벨이 사라진다
    /// (V14에서 실제로 그렇게 보이는 것을 스크린샷으로 확인했다 — 아이콘만 남았다).
    public static let linkChipWidth: CGFloat = 104
    /// 프로젝트/폴더 영역이 최소한 확보해야 하는 너비. 이보다 좁아지면 이름을 줄여 표시한다.
    public static let projectAreaMinimumWidth: CGFloat = 190

    /// 지금 화면에서 바가 쓸 수 있는 최대 너비.
    public static func maximumWidth(visibleFrameWidth: CGFloat) -> CGFloat {
        let usable = visibleFrameWidth - screenMargin
        return max(minimumBarWidth, min(maximumBarWidth, usable))
    }

    /// 인라인으로 보여줄 링크 수와, 더보기로 보낼 개수.
    ///
    /// 넘치는 링크를 **조용히 잘라내지 않는다.** 숨긴 개수를 UI가 "+N"으로 알리고,
    /// 그 항목들은 상세 보기에서 전부 접근할 수 있다.
    public static func linkBudget(total: Int, availableWidth: CGFloat) -> (visible: Int, hidden: Int) {
        guard total > 0 else { return (0, 0) }
        let usable = maximumWidth(visibleFrameWidth: availableWidth)
        let remaining = usable - fixedWidth - projectAreaMinimumWidth
        guard remaining > 0 else { return (0, total) }
        let visible = min(total, Int(remaining / linkChipWidth))
        return (visible, total - visible)
    }

    /// 링크 수에 맞춘 바 너비. 항목이 늘어도 최대 너비를 넘지 않는다.
    public static func barWidth(visibleLinkCount: Int, availableWidth: CGFloat) -> CGFloat {
        let needed = fixedWidth + projectAreaMinimumWidth + CGFloat(visibleLinkCount) * linkChipWidth
        return max(minimumBarWidth, min(maximumWidth(visibleFrameWidth: availableWidth), needed))
    }

    /// 창 전체 높이(바 + 상세 보기). 바 높이는 외형 설정에서 온다.
    public static func windowHeight(detailsVisible: Bool, barHeight: CGFloat = barHeight) -> CGFloat {
        barHeight + (detailsVisible ? detailsHeight : 0)
    }
}
