import Foundation

/// 화면에 그리는 항목 하나. **범위 + ID**를 함께 들고 다닌다(순번으로 실행하지 않는다).
public struct DockDisplayItem: Equatable, Sendable, Identifiable {
    public var ref: DockItemRef
    /// 표시 묶음(`ProjectResolution.allItems`)에서의 위치. 실행 계획 검증과 같은 목록을 가리키는지 확인용.
    public var index: Int
    public var item: DockItemTarget

    public init(ref: DockItemRef, index: Int, item: DockItemTarget) {
        self.ref = ref
        self.index = index
        self.item = item
    }

    public var id: String { ref.label }
}

/// 한 시점에 **실제로 화면에 그리는 목록**.
///
/// 화면·숨김 개수·키보드 이동이 모두 이 하나를 쓴다. 같은 판단을 두 곳에서 하면
/// 화면에 없는 항목으로 키보드가 이동하거나(또는 그 반대) 숨김 수가 어긋난다(V18.5 회귀).
public struct DockDisplay: Equatable, Sendable {
    /// 배치(`layout.order`) 순서대로의 화면 목록. **키보드 이동도 이 순서**를 쓴다.
    public var order: [DockDisplayItem]
    /// 공통 구역에서 자리가 없어 `+N`으로 밀린 수.
    public var commonHidden: Int
    /// 프로젝트 구역에서 자리가 없어 `⋯`로 밀린 수.
    public var projectHidden: Int
    /// 실제로 적용된 프로젝트 영역 폭(공간이 모자라면 최소 폭까지 줄어든다).
    public var projectAreaWidth: Double
    /// 창이 실제로 쓸 폭.
    public var barWidth: CGFloat
    /// 줄이기 전에 필요했던 폭. `barWidth`보다 크면 **공간 부족**이다.
    public var demandWidth: CGFloat
    public var isSpaceShort: Bool

    public init(
        order: [DockDisplayItem],
        commonHidden: Int,
        projectHidden: Int,
        projectAreaWidth: Double,
        barWidth: CGFloat,
        demandWidth: CGFloat,
        isSpaceShort: Bool
    ) {
        self.order = order
        self.commonHidden = commonHidden
        self.projectHidden = projectHidden
        self.projectAreaWidth = projectAreaWidth
        self.barWidth = barWidth
        self.demandWidth = demandWidth
        self.isSpaceShort = isSpaceShort
    }

    /// 아직 계산 전(첫 조회 전)의 빈 목록.
    public static let empty = DockDisplay(
        order: [],
        commonHidden: 0,
        projectHidden: 0,
        projectAreaWidth: DockLayout.defaultProjectAreaWidth,
        barWidth: DockBarLayout.minimumBarWidth,
        demandWidth: DockBarLayout.minimumBarWidth,
        isSpaceShort: false
    )

    public var visibleItemCount: Int { order.count }
    public var hiddenItemCount: Int { commonHidden + projectHidden }
    public var common: [DockDisplayItem] { order.filter(\.item.isCommon) }
    public var project: [DockDisplayItem] { order.filter { !$0.item.isCommon } }
}

/// 배치·화면 폭에 맞춘 바 기하 계산 결과.
public struct DockBarFit: Equatable, Sendable {
    public var barWidth: CGFloat
    public var demandWidth: CGFloat
    public var isSpaceShort: Bool
    public var projectAreaWidth: Double
    public var commonVisible: Int
    public var commonHidden: Int
}

extension DockBarLayout {
    /// 이 화면에서 바가 쓸 수 있는 폭의 상한.
    public static func screenCeiling(screenWidth: CGFloat) -> CGFloat {
        min(maximumBarWidth, max(minimumBarWidth, screenWidth - screenMargin * 2))
    }

    /// 화면에 실제로 그릴 구성요소(빈 구역은 자리도 차지하지 않는다). **화면과 같은 규칙**이다.
    public static func renderedComponents(layout: DockLayout, commonItemCount: Int) -> [DockComponent] {
        layout.order.filter { component in
            switch component {
            case .common: return commonItemCount > 0
            case .cards: return !layout.cards.isEmpty
            case .project: return true
            }
        }
    }

    /// 배치와 항목 수로 **바 폭·프로젝트 영역 폭·공통 타일 표시 수**를 한 번에 정한다.
    ///
    /// 규칙(승인된 V18):
    /// - 저장된 `layout`이 순서와 프로젝트 영역 폭을 정한다. 프로젝트 **항목 수로 다시 계산하지 않는다**.
    /// - 오른쪽 조작(상태 점·`⋯` 메뉴·가짜 배지)과 구분선 폭도 **여기서 함께 계산**한다
    ///   (빠뜨리면 그만큼 내용이 잘린다).
    /// - 공간이 모자라면 **프로젝트 영역을 최소 폭까지 줄인다**(그 영역 안에서 넘침으로 처리한다).
    /// - 그래도 모자라면 공통 타일이 `+N`으로 밀린다. **조용히 잘라내지 않는다** — 밀린 수를 화면에 남긴다.
    public static func barFit(
        layout: DockLayout,
        commonItemCount: Int,
        screenWidth: CGFloat,
        showsFakeBadge: Bool = false
    ) -> DockBarFit {
        let count = max(0, commonItemCount)
        let ceiling = screenCeiling(screenWidth: screenWidth)
        let components = renderedComponents(layout: layout, commonItemCount: count)
        let hasProject = components.contains(.project)
        let hasCards = components.contains(.cards)
        let cardsWidth: CGFloat = hasCards ? cardStripWidth(layout.cards) : 0

        let boundaries = CGFloat(max(0, components.count - 1))
        let chrome = widgetPadding * 2
            + boundaries * separatorStride
            + (components.isEmpty ? 0 : widgetGap)
            + trailingControlsWidth(showsFakeBadge: showsFakeBadge)

        func commonWidth(visible: Int, hidden: Int) -> CGFloat {
            // 넘침 타일(`+N`)도 타일 한 자리를 쓴다.
            let tiles = visible + (hidden > 0 ? 1 : 0)
            guard tiles > 0 else { return 0 }
            return CGFloat(tiles) * appTileSize + CGFloat(tiles - 1) * tileGap
        }
        func demand(area: Double, commonTiles: CGFloat) -> CGFloat {
            chrome + cardsWidth + commonTiles + (hasProject ? CGFloat(area) : 0)
        }

        // 1) 그대로 들어가는가.
        let full = demand(area: layout.projectAreaWidth, commonTiles: commonWidth(visible: count, hidden: 0))
        if full <= ceiling {
            return DockBarFit(
                barWidth: max(minimumBarWidth, full),
                demandWidth: full,
                isSpaceShort: false,
                projectAreaWidth: layout.projectAreaWidth,
                commonVisible: count,
                commonHidden: 0
            )
        }

        // 2) 프로젝트 영역을 최소 폭까지 줄인다(항목 수가 아니라 영역 폭을 먼저 양보한다).
        //    **저장된 폭을 그대로 쓸 수 없다는 사실도 공간 부족이다** — 조용히 줄이지 않고 화면에 남긴다.
        let area = hasProject
            ? max(DockLayout.minimumProjectAreaWidth, layout.projectAreaWidth - Double(full - ceiling))
            : layout.projectAreaWidth
        let afterArea = demand(area: area, commonTiles: commonWidth(visible: count, hidden: 0))
        if afterArea <= ceiling {
            return DockBarFit(
                barWidth: max(minimumBarWidth, afterArea),
                demandWidth: full,
                isSpaceShort: true,
                projectAreaWidth: area,
                commonVisible: count,
                commonHidden: 0
            )
        }

        // 3) 공통 타일도 자리가 모자란다 → 넘침 타일 자리를 하나 남기고 밀어낸다(밀린 수는 화면에 남는다).
        let roomForCommon = max(0, ceiling - chrome - cardsWidth - CGFloat(hasProject ? area : 0))
        let fits = roomForCommon >= appTileSize ? Int((roomForCommon + tileGap) / appTileStride) : 0
        let visible = count <= fits ? count : max(0, fits - 1)
        let hidden = count - visible
        let width = demand(area: area, commonTiles: commonWidth(visible: visible, hidden: hidden))
        return DockBarFit(
            barWidth: min(ceiling, max(minimumBarWidth, width)),
            demandWidth: full,
            isSpaceShort: true,
            projectAreaWidth: area,
            commonVisible: visible,
            commonHidden: hidden
        )
    }

    /// 카드 한 줄의 폭(카드 사이 간격 포함).
    public static func cardStripWidth(_ cards: [DockCardSpec]) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        let cards_ = cards.reduce(CGFloat(0)) { $0 + ($1.kind == .clock ? clockCardWidth : timerCardWidth) }
        return cards_ + CGFloat(cards.count - 1) * cardGap
    }
}

/// 표시 목록을 만드는 **유일한 곳**.
public enum DockDisplayBuilder {
    /// 배치·항목 묶음·화면 폭 → 화면에 그릴 목록과 숨김 수.
    public static func make(
        resolution: ProjectResolution,
        layout: DockLayout,
        screenWidth: CGFloat,
        showsFakeBadge: Bool = false
    ) -> DockDisplay {
        let fit = DockBarLayout.barFit(
            layout: layout,
            commonItemCount: resolution.commonItems.count,
            screenWidth: screenWidth,
            showsFakeBadge: showsFakeBadge
        )
        let projectBudget = DockBarLayout.projectTileBudget(
            width: fit.projectAreaWidth,
            tileCount: resolution.projectItems.count
        )

        var items: [DockDisplayItem] = []
        for (index, item) in resolution.commonItems.prefix(max(0, fit.commonVisible)).enumerated() {
            items.append(DockDisplayItem(ref: item.ref, index: index, item: item))
        }
        for (index, item) in resolution.projectItems.prefix(max(0, projectBudget.visible)).enumerated() {
            items.append(
                DockDisplayItem(
                    ref: item.ref,
                    index: resolution.commonItems.count + index,
                    item: item
                )
            )
        }

        // 배치가 정한 순서대로 화면에 놓는다. 키보드 이동도 같은 순서를 쓴다.
        let ordered = layout.order.flatMap { component -> [DockDisplayItem] in
            switch component {
            case .common: return items.filter(\.item.isCommon)
            case .project: return items.filter { !$0.item.isCommon }
            case .cards: return []
            }
        }

        return DockDisplay(
            order: ordered,
            commonHidden: fit.commonHidden,
            projectHidden: projectBudget.hidden,
            projectAreaWidth: fit.projectAreaWidth,
            barWidth: fit.barWidth,
            demandWidth: fit.demandWidth,
            isSpaceShort: fit.isSpaceShort
        )
    }
}

// MARK: - 키보드 이동 계획

/// 키보드가 이동하는 곳. **화면에 있는 것만** 들어간다.
public enum DockFocusControl: Equatable, Sendable {
    case item(DockItemRef)
    /// 상세 보기 열기/닫기(바의 상태 점). 화면에 항상 있다.
    case details
    /// 상세 보기 안의 숨기기·종료.
    case hide
    case quit

    public var label: String {
        switch self {
        case .item(let ref): return "item:\(ref.label)"
        case .details: return "details"
        case .hide: return "hide"
        case .quit: return "quit"
        }
    }

    public var itemRef: DockItemRef? {
        if case .item(let ref) = self { return ref }
        return nil
    }
}

public enum DockFocusPlan {
    /// 지금 화면에서 키보드로 이동할 수 있는 것들.
    ///
    /// - 상세 보기가 닫혀 있으면 **표시 목록과 같은 항목**만 순회한다(화면에 없는 것을 고르지 않는다).
    /// - 상세 보기가 열려 있으면 그 목록에 **전부** 나열되므로 밀린 항목까지 순회한다.
    public static func controls(
        display: DockDisplay,
        allItems: [DockItemTarget],
        detailsVisible: Bool
    ) -> [DockFocusControl] {
        var controls: [DockFocusControl] = (detailsVisible ? allItems.map(\.ref) : display.order.map(\.ref))
            .map { DockFocusControl.item($0) }
        controls.append(.details)
        if detailsVisible {
            controls.append(contentsOf: [.hide, .quit])
        }
        return controls
    }
}
