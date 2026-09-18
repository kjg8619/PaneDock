import Foundation

/// 가로형 Dock 바의 **배치 계산만** 담당한다. 그리기는 UI가 한다.
///
/// 여기 두는 이유: 항목이 많아질 때 무엇을 인라인으로 보여주고 무엇을 더보기로 보낼지,
/// 창이 화면을 넘지 않는지는 **규칙**이라 검사로 고정할 수 있어야 하기 때문이다.
/// 실제 화면 측정은 UI가 하고, 이 계산은 숫자만 받는다.
public enum DockBarLayout {
    /// 바 높이. 첫 시안은 64~80pt 범위로 잡고 가독성·클릭 영역을 보고 조정한다.
    /// 승인된 구성형 배치의 기본 높이(104pt). 크기 선택은 이 값을 기준으로 움직인다.
    public static let widgetBarHeight: CGFloat = 104
    /// 상세 보기 높이(열렸을 때 바 위로 펼쳐진다).
    public static let detailsHeight: CGFloat = 300
    /// 공통 앱 타일 / 프로젝트 항목 타일.
    public static let appTileSize: CGFloat = 68
    public static let projectTileSize: CGFloat = 48
    public static let cardHeight: CGFloat = 68

    /// 구성형 화면의 조각별 크기·간격(승인된 위젯 규격).
    public static let widgetPadding: CGFloat = 16
    public static let widgetGap: CGFloat = 12
    /// 타일 사이 간격(앱 68pt·프로젝트 48pt 공통).
    public static let tileGap: CGFloat = 8
    /// 카드 사이 간격.
    public static let cardGap: CGFloat = 8
    /// 오른쪽 조작(상태 점·⋯ 메뉴)과 가짜 모드 표시의 폭. **바 기하 계산에 포함**한다
    /// (포함하지 않으면 그만큼 내용이 잘린다 — V18.5에서 오른쪽 조작이 밀려난 것을 화면으로 확인).
    public static let stateDotWidth: CGFloat = 30
    /// `⋯` 메뉴 버튼(승인 시안: 40pt · 둥근 모서리 12).
    public static let menuButtonWidth: CGFloat = 40
    public static let fakeBadgeWidth: CGFloat = 44
    public static let controlGap: CGFloat = 6
    public static let minimumTrailingGap: CGFloat = 6
    public static let appTileStride: CGFloat = appTileSize + tileGap
    public static let projectTileStride: CGFloat = projectTileSize + tileGap
    /// `아이콘+이름` 모드의 프로젝트 항목 칩 폭(아이콘 + 이름). 48pt 타일에는 이름이 들어가지 않는다.
    public static let projectTileChipWidth: CGFloat = 112
    /// 자리가 없어 밀린 카드를 알리는 타일의 폭(카드 높이와 같다).
    public static let cardOverflowTileWidth: CGFloat = 68

    /// 항목 타일 폭. **표시 모드에 따라 다르다**(아이콘 중심 48 / 아이콘+이름 112).
    public static func projectTileWidth(_ mode: DockLabelMode) -> CGFloat {
        mode == .iconOnly ? projectTileSize : projectTileChipWidth
    }

    public static func projectTileStride(_ mode: DockLabelMode) -> CGFloat {
        projectTileWidth(mode) + tileGap
    }

    /// 앱 타일 폭. 두 모드 모두 68pt이고, 이름은 **타일 안**에 들어간다(아이콘이 조금 작아진다).
    public static func appTileWidth(_ mode: DockLabelMode) -> CGFloat {
        _ = mode
        return appTileSize
    }

    /// 할당 폭 안에 들어가는 프로젝트 항목 수와 밀린 수(표시 모드 반영).
    public static func projectTileBudget(
        width: Double,
        tileCount: Int,
        labelMode: DockLabelMode = .iconOnly
    ) -> (visible: Int, hidden: Int) {
        let stride = projectTileStride(labelMode)
        let fits = max(0, Int((width - widgetPadding) / stride))
        guard tileCount > fits else { return (tileCount, 0) }
        let visible = max(0, fits - 1)
        return (visible, tileCount - visible)
    }

    /// 할당 폭 안에 들어가는 카드 수와 밀린 수. 밀린 카드가 있으면 **`+N` 타일 자리를 남긴다**.
    ///
    /// 여러 카드를 두어 화면보다 넓어지는 구성에서 조용히 잘리지 않게 하는 규칙이다.
    public static func cardBudget(width: CGFloat, cards: [DockCardSpec]) -> (visible: Int, hidden: Int) {
        guard !cards.isEmpty else { return (0, 0) }
        let total = cardStripWidth(cards)
        guard total > width else { return (cards.count, 0) }

        let limit = width - (cardGap + cardOverflowTileWidth)
        var used: CGFloat = 0
        var visible = 0
        for (index, card) in cards.enumerated() {
            let step = (index > 0 ? cardGap : 0) + cardWidth(card)
            if used + step > max(0, limit) { break }
            used += step
            visible = index + 1
        }
        return (visible, cards.count - visible)
    }

    /// 카드 하나의 폭.
    public static func cardWidth(_ card: DockCardSpec) -> CGFloat {
        card.kind == .clock ? clockCardWidth : timerCardWidth
    }
    /// 시계 카드는 **아날로그 시계 + 큰 시간 + 날짜**가 함께 들어가야 한다.
    /// 104pt에서는 날짜가 잘려 "9월…"까지만 보였다(화면 확인). 승인 시안의 내용 폭에 맞춘다.
    public static let clockCardWidth: CGFloat = 152
    public static let timerCardWidth: CGFloat = 168

    /// 구성요소 사이 구분선 하나가 차지하는 폭(선 + 양쪽 간격).
    public static let separatorStride: CGFloat = 1 + widgetGap * 2

    /// 오른쪽 조작 묶음의 폭(최소 여백 포함).
    ///
    /// 묶음은 `[여백][가짜 배지?][상태 점][⋯ 메뉴]`이고 **사이 간격까지** 포함한다.
    public static func trailingControlsWidth(showsFakeBadge: Bool) -> CGFloat {
        let controls = (showsFakeBadge ? 1 : 0) + 2   // [가짜 배지] + 상태 점 + ⋯ 메뉴
        let gaps = (controls + 1) - 1                 // 여백 + 조작들 사이
        return minimumTrailingGap
            + (showsFakeBadge ? fakeBadgeWidth : 0)
            + stateDotWidth
            + menuButtonWidth
            + CGFloat(gaps) * controlGap
    }

    /// 구성형 화면의 바 너비.
    ///
    /// **저장된 배치가 순서와 고정 폭(프로젝트 영역)을 정한다.** 항목 수로 다시 계산하지 않으므로
    /// 프로젝트 항목이 2개든 8개든 **공통 영역의 위치가 밀리지 않는다**(영역 안에서 넘침을 처리한다).
    /// 공간이 모자라는 경우의 판단은 `barFit` 한 곳에서만 한다.
    public static func widgetBarWidth(
        layout: DockLayout,
        commonItemCount: Int,
        screenWidth: CGFloat
    ) -> CGFloat {
        barFit(layout: layout, commonItemCount: commonItemCount, screenWidth: screenWidth).barWidth
    }

    /// 바 최소 너비. 항목이 없어도 주요 조작이 뭉개지지 않게 한다.
    public static let minimumBarWidth: CGFloat = 460
    /// 자동 접기 상태에서 남기는 **호출 손잡이** 크기.
    /// 화면 가장자리로 숨기는 방식이 아니라, 지금 위치에 작게 남아 마우스를 받는 영역이다.
    public static let handleWidth: CGFloat = 168
    public static let handleHeight: CGFloat = 30
    /// 바 최대 너비. 이보다 넓어지면 화면을 넘지 않도록 줄이고, 넘치는 항목은 영역 안에서 밀어낸다.
    /// V18 위젯 배치(앱 3 + 카드 2 + 영역 360)가 약 1090pt라 기존 1100으로는 여유가 없었다.
    /// 화면 여백(`screenMargin`)이 실질 상한이며, 이 값은 그보다 좁은 화면을 위한 안전 상한이다.
    public static let maximumBarWidth: CGFloat = 1_240
    /// 화면 가장자리에서 남길 여백(양쪽 합계).
    public static let screenMargin: CGFloat = 48

    /// 창 전체 높이(바 + 상세 보기). 바 높이는 외형 설정에서 온다.
    public static func windowHeight(detailsVisible: Bool, barHeight: CGFloat = widgetBarHeight) -> CGFloat {
        barHeight + (detailsVisible ? detailsHeight : 0)
    }
}
