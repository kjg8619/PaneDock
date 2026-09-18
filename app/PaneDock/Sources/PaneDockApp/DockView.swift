/// 항목 종류별 기호(앱 아이콘을 못 읽었을 때의 대체).
private func itemSymbol(for kind: DockItemKind) -> String {
    switch kind {
    case .app: return "app"
    case .folder: return "folder"
    case .link: return "link"
    }
}

/// 앱 항목의 실제 아이콘. 폴더·링크는 타일 색과 기호·이니셜로 구분한다.
private func itemIconImage(for item: DockItemTarget) -> NSImage? {
    guard item.kind == .app else { return nil }
    let image = NSWorkspace.shared.icon(forFile: item.target)
    // 실제 앱 아이콘을 **그대로** 그린다(단색 템플릿으로 바뀌면 앱을 알아볼 수 없다).
    image.isTemplate = false
    return image
}

/// 항목 실행 툴팁. 종류에 따라 무엇이 열리는지 밝힌다.
private func itemHelp(for item: DockItemTarget) -> String {
    switch item.kind {
    case .app: return "앱 열기 — \(item.name) (\(item.target))"
    case .folder: return "폴더 열기 — \(item.name) (\(item.target))"
    case .link: return "링크 열기 — \(item.name) (\(item.target))"
    }
}

import AppKit
import FocusProbeCore
import SwiftUI

/// 가로형 Dock 바 + 상세 보기. **승인된 V18 위젯형 화면**이다.
///
/// ## 화면 규칙
///
/// - 구성은 **저장된 배치(`layout.order`)** 가 정한다: 공통 앱 타일(68pt) · 카드(시계·타이머) ·
///   프로젝트 영역(폭 고정, 48pt 타일). 고정된 HStack 순서를 쓰지 않는다.
/// - **상태는 색만으로 전달하지 않는다.** 항상 아이콘·기호·한국어 이름을 함께 보여준다.
/// - 평소에는 이름을 줄이고, 전체 경로·pane ID·경로 출처·연결 상태·상세 사유는 **상세 보기**로 보낸다.
/// - 오류를 숨기는 것이 목적이 아니다. 확인 불가·오류는 바에서 즉시 보이고,
///   선택하면 구체적인 이유를 볼 수 있다.
/// - 영역 안에 다 못 들어간 항목은 **`+N`·`⋯` 타일로 밀린 수를 남긴다**(조용히 자르지 않는다).
///   공간 자체가 모자라면 프로젝트 영역을 최소 폭까지 줄이고, 그 사실을 상세 보기와 메뉴에 남긴다.
///
/// ## 조작
///
/// 모든 조작은 기존 실제 기능(`DockModel`)에 연결돼 있다. 동작 없는 항목은 만들지 않는다.
/// 마우스와 키보드가 같은 검증 경로를 쓴다. hover와 키보드 선택은 다르게 표시한다.
struct DockView: View {
    @ObservedObject var model: DockModel

    private var availableWidth: CGFloat {
        ScreenGeometry.fallbackFrame.width
    }

    var body: some View {
        if model.isCollapsed { collapsedHandle } else { expandedBody }
    }

    /// 자동 접기 상태에서 남는 **호출 손잡이**.
    /// 화면 가장자리로 숨기는 방식이 아니라, 지금 자리에 작게 남아 마우스를 받는다.
    private var collapsedHandle: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text("Dock").font(.caption2).bold().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            // hover만으로 펼친다. **호출 세션(키보드 선택·고정)은 시작하지 않는다.**
            if inside { model.expandFromHandle() }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .help("Dock이 접혀 있습니다 — 마우스를 올리면 펼쳐집니다. 타이머는 계속 진행됩니다")
        .accessibilityLabel("Dock 호출 손잡이")
        .accessibilityHint("마우스를 올리거나 단축키로 Dock을 펼칩니다")
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            if model.isDetailsVisible {
                // 상세 보기는 **바 위로** 펼쳐진다. 창 크기는 AppDelegate가 맞춘다.
                DockDetailsView(model: model, availableWidth: availableWidth)
                Divider()
            }
            bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 4)
    }

    // MARK: - 바 (배치 순서대로)

    private var bar: some View {
        HStack(spacing: DockBarLayout.widgetGap) {
            ForEach(renderedComponents, id: \.self) { component in
                // 구성요소 경계는 첫 요소를 뺀 나머지 앞에만 둔다(빈 구역은 여기 오지 않는다).
                if component != renderedComponents.first { componentSeparator }
                componentView(component)
            }
            rightCluster
        }
        .padding(.horizontal, DockBarLayout.widgetPadding)
        .frame(height: model.effectiveAppearance.size.barHeight)
        // 빈 영역에서만 창을 끌 수 있다. 타일·카드 위에서는 클릭이 그대로 동작한다.
        .background(WindowDragHandle())
    }

    /// 실제로 그릴 구성요소(빈 구역은 자리도 차지하지 않는다). **바 폭 계산과 같은 규칙**을 쓴다.
    private var renderedComponents: [DockComponent] {
        DockBarLayout.renderedComponents(
            layout: model.effectiveLayout,
            commonItemCount: model.resolution.commonItems.count
        )
    }

    @ViewBuilder
    private func componentView(_ component: DockComponent) -> some View {
        switch component {
        case .common: commonComponent
        case .cards: cardsComponent
        case .project: projectComponent
        }
    }

    private var componentSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 52)
    }

    // MARK: - 공통 앱 구역 (68pt 타일)

    /// 이름을 보여주는 모드인가(두 모드가 **실제로 다르게** 그려져야 한다).
    private var showsLabels: Bool { model.effectiveAppearance.labelMode.showsItemLabels }

    private var commonComponent: some View {
        HStack(spacing: DockBarLayout.tileGap) {
            ForEach(model.display.common) { entry in
                appTile(entry)
            }
            if model.display.commonHidden > 0 {
                overflowTile(
                    count: model.display.commonHidden,
                    size: DockBarLayout.appTileSize,
                    radius: 17,
                    focus: .overflow(.common),
                    help: "자리가 없어 밀린 공통 항목 \(model.display.commonHidden)개 — 상세 보기에서 전부 확인할 수 있습니다"
                )
            }
        }
    }

    private func appTile(_ entry: DockDisplayItem) -> some View {
        let item = entry.item
        let ref = entry.ref
        return Button(action: { model.performItem(ref: ref, source: .mouse) }) {
            VStack(spacing: 2) {
                tileFace(for: item, iconSize: showsLabels ? 34 : 40, symbolSize: 26, letterSize: 26)
                if showsLabels {
                    // 아이콘+이름 모드: 타일 안에 이름을 넣는다(아이콘은 조금 작아진다).
                    Text(item.name)
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 2)
                }
            }
            .frame(width: DockBarLayout.appTileWidth(model.effectiveAppearance.labelMode),
                   height: DockBarLayout.appTileSize)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(tileGradient(for: item))
            )
            .overlay(alignment: .bottom) {
                if model.runningAppPaths.contains(item.target) {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .offset(y: -5)
                }
            }
            .overlay(focusRing(for: .item(ref), radius: 17))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.setHover(inside ? .item(ref) : (model.hoveredItem == .item(ref) ? nil : model.hoveredItem))
        }
        .help(itemHelp(for: item))
        .accessibilityLabel(itemHelp(for: item))
    }

    // MARK: - 카드 구역

    private var cardsComponent: some View {
        HStack(spacing: DockBarLayout.cardGap) {
            ForEach(model.display.visibleCards) { card in
                switch card.kind {
                case .clock:
                    ClockCardView(now: model.now)
                case .focusTimer:
                    FocusTimerCardView(
                        cardID: card.id,
                        state: model.timerState(for: card.id),
                        now: model.now,
                        focusedControl: model.focusedItem,
                        hoveredControl: model.hoveredItem,
                        onAction: { action in model.performTimer(action, cardID: card.id, source: .mouse) },
                        onHover: { control in model.setHover(control) }
                    )
                }
            }
            if model.display.cardHidden > 0 {
                // 카드가 화면보다 많을 때: **조용히 잘리지 않는다.** 밀린 수를 남기고 상세 보기로 안내한다.
                overflowTile(
                    count: model.display.cardHidden,
                    size: DockBarLayout.cardOverflowTileWidth,
                    radius: 17,
                    height: DockBarLayout.cardHeight,
                    focus: .overflow(.cards),
                    help: "자리가 없어 밀린 카드 \(model.display.cardHidden)개 — 타이머는 계속 진행됩니다. 상세 보기에서 확인할 수 있습니다"
                )
            }
        }
    }

    // MARK: - 프로젝트 영역 (폭 고정 · 내부에서 넘침 처리)

    /// 프로젝트 패널(A 시안): **작은 헤더 + 아래 도구 타일**. 점선·모서리 라벨을 쓰지 않는다.
    ///
    /// - 외부 폭(`projectAreaWidth`)과 공통 구성 위치는 그대로다. 바깥 높이·여백·표현만 바꾼다.
    /// - 헤더는 별도 줄이라 **타일 한 줄의 폭을 잠식하지 않는다**(더보기 계산은 그대로 유지된다).
    /// - 진단 정보(전체 경로·pane·연결 상태)는 기존 상세 보기에서 계속 본다.
    private var projectComponent: some View {
        VStack(alignment: .leading, spacing: 4) {
            panelHeader
            panelBody
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: model.display.projectAreaWidth, height: DockBarLayout.projectPanelHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(panelStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(areaAccessibilityLabel)
    }

    /// 패널 상태 — 코어의 한 곳(`DockPanelStatus`)에서만 판단한다.
    private var panelStatus: DockPanelStatus {
        DockPanelStatus.from(state: model.state, hasProject: model.display.projectRegistered)
    }

    /// 패널 배경: 등록은 밝은 패널, 미등록은 주황 기운, 확인 중은 중립, 오류는 붉은 기운.
    private var panelFill: Color {
        switch panelStatus {
        case .registered: return Color.primary.opacity(0.07)
        case .unregistered: return Color.orange.opacity(0.10)
        case .pending: return Color.primary.opacity(0.05)
        case .failure: return Color.red.opacity(0.08)
        }
    }

    private var panelStroke: Color {
        switch panelStatus {
        case .registered: return Color.primary.opacity(0.14)
        case .unregistered: return Color.orange.opacity(0.40)
        case .pending: return Color.primary.opacity(0.20)
        case .failure: return Color.red.opacity(0.35)
        }
    }

    /// 헤더: 상태 점 · 프로젝트 이름 · 보조(호스트) 정보 · 메뉴.
    private var panelHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(panelStatusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(panelTitle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(panelTitleHelp)
            if let host = panelHostLabel {
                Text(host)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                    )
                    .help("이 경로를 알려준 터미널 소스")
            }
            Spacer(minLength: 4)
            // 헤더의 메뉴 — 바 오른쪽 `⋯`와 **같은 메뉴**를 연다(메뉴를 두 벌 만들지 않는다).
            Button(action: { model.showActionMenu(source: .mouse) }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("프로젝트 영역 메뉴 — 상세 보기 · 폴더 열기 · 경로 복사 · 표시 대상 고정")
            .accessibilityLabel("프로젝트 영역 메뉴")
        }
        .frame(height: DockBarLayout.projectPanelHeaderHeight)
    }

    /// 패널 본문: 등록된 프로젝트는 도구 타일, 미등록은 안내 + 조작, 확인 실패는 사유.
    @ViewBuilder
    private var panelBody: some View {
        if panelStatus == .registered {
            HStack(spacing: DockBarLayout.tileGap) {
                ForEach(model.display.project) { entry in
                    projectTile(entry)
                }
                if model.display.projectHidden > 0 {
                    overflowTile(
                        count: model.display.projectHidden,
                        size: DockBarLayout.projectTileWidth(model.effectiveAppearance.labelMode),
                        radius: 13,
                        height: DockBarLayout.projectTileSize,
                        focus: .overflow(.project),
                        help: "이 영역에 다 들어가지 않은 항목 \(model.display.projectHidden)개 — 상세 보기에서 전부 확인할 수 있습니다"
                    )
                }
                addToolTile
            }
        } else if panelStatus == .unregistered {
            // 경로는 **유효하지만 등록된 프로젝트가 없다**(확인 중·오류와 다른 상태).
            HStack(spacing: 8) {
                Text("이 경로에 등록된 프로젝트가 없습니다")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("폴더 열기") { model.perform(.openFolder, source: .mouse) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .overlay(focusRing(for: .projectOpenFolder, radius: 6))
                    .disabled(!model.state.canOpenFolder)
                    .help(model.state.canOpenFolder
                        ? "지금 경로를 Finder로 엽니다 — \(model.state.fullPath ?? "-")"
                        : "지금은 열 수 없습니다: \(model.state.detail ?? "실행할 대상을 확인하는 중입니다")")
                Button("프로젝트로 등록") { model.openEditor() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .overlay(focusRing(for: .registerProject, radius: 6))
                    .help("Dock 편집을 열어 이 경로를 프로젝트로 등록합니다")
            }
        } else {
            // 확인 중(pending)과 오류(failure) — 미등록과 같은 문구를 쓰지 않고, 실행 제한도 풀지 않는다.
            Text(model.state.detail ?? (panelStatus == .pending ? "경로를 확인하는 중입니다" : "경로를 확인할 수 없습니다"))
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var panelStatusColor: Color {
        switch panelStatus {
        case .registered: return .green
        case .unregistered: return .orange
        case .pending: return .gray
        case .failure: return .red
        }
    }

    private var panelTitle: String {
        switch panelStatus {
        case .registered: return model.resolution.projectName
        case .unregistered: return "프로젝트 미등록"
        case .pending: return "경로 확인 중"
        case .failure: return "경로 확인 실패"
        }
    }

    private var panelTitleHelp: String {
        if model.display.projectRegistered {
            return "프로젝트 \(model.resolution.projectName) — 기준 폴더 \(model.resolution.projectRoot)"
        }
        return model.state.fullPath ?? model.state.detail ?? "아직 경로를 확인하지 못했습니다"
    }

    /// 헤더의 보조 정보(어느 터미널 소스가 알려준 경로인가). 진단 상세는 상세 보기에 있다.
    private var panelHostLabel: String? {
        guard let host = model.state.hostAppID, !host.isEmpty else { return nil }
        return host
    }

    /// 등록된 프로젝트에서 **추가**로 가는 타일(A 시안의 `＋ 추가`).
    private var addToolTile: some View {
        Button(action: { model.openEditor() }) {
            VStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: DockBarLayout.projectTileSize, height: DockBarLayout.projectTileSize)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    )
                    .overlay(focusRing(for: .projectAdd, radius: 13))
                if showsLabels {
                    Text("추가").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: DockBarLayout.projectTileWidth(model.effectiveAppearance.labelMode),
                   height: DockBarLayout.cardHeight, alignment: .top)
        }
        .buttonStyle(.plain)
        .help("Dock 편집을 열어 항목·배치를 바꿉니다")
        .accessibilityLabel("프로젝트 도구 추가 — Dock 편집 열기")
    }

    private var areaAccessibilityLabel: String {
        // 등록 여부보다 **실제 작업 상태**를 먼저 반영한다(경로 정보가 남아 있어도 오류면 오류로 알린다).
        if panelStatus == .registered {
            return "프로젝트 영역 \(model.resolution.projectName), 항목 \(model.display.project.count)개 표시"
        }
        switch panelStatus {
        case .registered:
            return "프로젝트 영역 \(model.resolution.projectName)"
        case .unregistered:
            return "프로젝트 영역 — 프로젝트 미등록(폴더 열기·프로젝트로 등록 가능)"
        case .pending:
            return "프로젝트 영역 — 경로 확인 중"
        case .failure:
            return "프로젝트 영역 — 경로 확인 실패: \(model.state.detail ?? "-")"
        }
    }

    private func projectTile(_ entry: DockDisplayItem) -> some View {
        let item = entry.item
        let ref = entry.ref
        let width = DockBarLayout.projectTileWidth(model.effectiveAppearance.labelMode)
        return Button(action: { model.performItem(ref: ref, source: .mouse) }) {
            VStack(spacing: 3) {
                // 아이콘은 A 시안처럼 **정사각 타일**로 두고, 이름은 아래에 짧게 붙인다.
                tileFace(for: item, iconSize: 26, symbolSize: 19, letterSize: 19)
                    .frame(width: DockBarLayout.projectTileSize, height: DockBarLayout.projectTileSize)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(tileGradient(for: item))
                    )
                    .overlay(focusRing(for: .item(ref), radius: 13))
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                if showsLabels {
                    Text(item.name)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary.opacity(0.85))
                }
            }
            .frame(width: width, height: DockBarLayout.cardHeight, alignment: .top)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.setHover(inside ? .item(ref) : (model.hoveredItem == .item(ref) ? nil : model.hoveredItem))
        }
        .help(itemHelp(for: item))
        .accessibilityLabel(itemHelp(for: item))
    }

    /// 영역·구역에서 밀린 항목·카드를 알리는 타일(클릭하면 상세 보기에서 전부 볼 수 있다).
    private func overflowTile(
        count: Int,
        size: CGFloat,
        radius: CGFloat,
        height: CGFloat? = nil,
        focus: DockFocusControl,
        help: String
    ) -> some View {
        Button(action: { model.showDetails() }) {
            Text("+\(count)")
                .font(.system(size: size > 50 ? 14 : 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: height ?? size)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                )
                .overlay(focusRing(for: focus, radius: radius))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 키보드 선택 테두리. 마우스 hover와 **다르게** 보이게 한다.
    private func focusRing(for control: DockFocusControl, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(model.focusedItem == control ? Color.accentColor : Color.clear, lineWidth: 2.5)
    }

    // MARK: - 오른쪽 조작 (상태 점 · ⋯ 메뉴)

    private var rightCluster: some View {
        HStack(spacing: DockBarLayout.controlGap) {
            // 남는 공간은 여기서 흡수한다(타일·카드·영역은 자기 폭을 지킨다).
            Spacer(minLength: DockBarLayout.minimumTrailingGap)
            if model.isFake {
                // 테두리 없는 패널이라 창 제목이 없다 → 가짜 모드 표시를 바 안에 둔다.
                // 폭을 고정해 **바 기하 계산과 화면이 어긋나지 않게** 한다.
                Text("FAKE")
                    .font(.caption2).bold()
                    .foregroundStyle(.white)
                    .frame(width: DockBarLayout.fakeBadgeWidth)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
                    .fixedSize()
                    .help("가짜 데이터 모드입니다. 실제 터미널에 연결되지 않았습니다")
                    .accessibilityLabel("가짜 데이터 모드")
            }
            stateDot
            actionMenu
        }
    }

    /// 상태를 **점 하나**로 줄였다(승인된 배치). 색만으로 전달하지 않는다는 규칙은
    /// 툴팁·접근성 이름·상세 보기로 지킨다. 클릭하면 상세 정보가 열린다(키보드 초점의 앵커).
    private var stateDot: some View {
        Button(action: { model.toggleDetails() }) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(stateColor.opacity(0.35), lineWidth: 3).padding(-3))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.focusedItem == .details ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .help("\(stateLabel) — \(shortStatusHelp)\n클릭하면 상세 정보를 \(model.isDetailsVisible ? "닫습니다" : "엽니다")")
        .accessibilityLabel("상태: \(stateLabel)")
        .accessibilityHint(model.isDetailsVisible ? "상세 정보를 닫습니다" : "상세 정보를 엽니다")
    }

    /// 보조 동작은 **작은 ⋯ 메뉴**로 접는다(승인된 배치).
    ///
    /// 마우스와 키보드가 **같은 메뉴**를 연다(메뉴를 두 벌 만들지 않는다).
    /// 버튼 자리를 모델에 알려 주어 키보드로 열 때도 같은 자리에 뜬다.
    private var actionMenu: some View {
        Button(action: { model.showActionMenu(source: .mouse) }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: DockBarLayout.menuButtonWidth, height: DockBarLayout.menuButtonWidth)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .overlay(focusRing(for: .menu, radius: 12))
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { model.reportMenuAnchor(proxy.frame(in: .global)) }
                            .onChange(of: proxy.frame(in: .global)) { model.reportMenuAnchor($0) }
                    }
                )
        }
        .buttonStyle(.plain)
        .help("보조 동작: 상세 보기 · 현재 폴더 열기 · 경로 복사 · 표시 대상 고정")
        .accessibilityLabel("보조 동작 메뉴")
    }

    // MARK: - 타일 모양

    /// 타일 배경(승인 시안의 타일 표현). 앱은 **아이콘 뒤에 색이 깔리고**, 폴더는 색 + 이니셜,
    /// 링크는 파랑 계열이다. 색은 항목 id로 정해 실행마다 같다.
    private func tileGradient(for item: DockItemTarget) -> LinearGradient {
        let colors: [Color]
        switch item.kind {
        case .app:
            let tint = folderColors[stableColorIndex(for: item.itemID)][0]
            colors = [tint.opacity(0.55), tint.opacity(0.28)]
        case .link:
            colors = [Color(red: 0.50, green: 0.76, blue: 1.0), Color(red: 0.24, green: 0.50, blue: 0.85)]
        case .folder:
            colors = folderColors[stableColorIndex(for: item.itemID)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func tileFace(for item: DockItemTarget, iconSize: CGFloat, symbolSize: CGFloat, letterSize: CGFloat) -> some View {
        Group {
            if let image = itemIconImage(for: item) {
                Image(nsImage: image).resizable().frame(width: iconSize, height: iconSize)
            } else if item.kind == .folder {
                Text(folderInitial(for: item.name))
                    .font(.system(size: letterSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.72))
                    .lineLimit(1)
            } else {
                Image(systemName: itemSymbol(for: item.kind))
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func folderInitial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// 항목 id로 **실행마다 같은** 색을 고른다(Swift `hashValue`는 실행마다 달라져 쓸 수 없다).
    private func stableColorIndex(for id: String) -> Int {
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return sum % folderColors.count
    }

    /// 승인 시안의 색(폴더 색 + 앱 타일 색조).
    private var folderColors: [[Color]] {
        [
            [Color(red: 1.00, green: 0.82, blue: 0.40), Color(red: 0.94, green: 0.65, blue: 0.17)],
            [Color(red: 0.48, green: 0.83, blue: 0.63), Color(red: 0.20, green: 0.63, blue: 0.42)],
            [Color(red: 0.78, green: 0.66, blue: 1.00), Color(red: 0.54, green: 0.39, blue: 0.88)],
            [Color(red: 1.00, green: 0.64, blue: 0.55), Color(red: 0.85, green: 0.42, blue: 0.45)],
            [Color(red: 0.55, green: 0.85, blue: 0.92), Color(red: 0.24, green: 0.58, blue: 0.72)],
        ]
    }

    // MARK: - 문구

    private var stateLabel: String {
        switch model.state.display {
        case .tracked: return "추적 중"
        case .held: return "유지 중"
        case .locked: return "잠금"
        case .pending: return "확인 중"
        case .error: return "오류"
        }
    }

    private var stateColor: Color {
        switch model.state.display {
        case .tracked: return .green
        case .held: return .orange
        case .locked: return .blue
        case .pending: return .gray
        case .error: return .red
        }
    }

    private var shortStatusHelp: String {
        if let detail = model.state.detail { return "\(stateLabel) — \(detail)" }
        switch model.state.display {
        case .tracked: return "포커스된 터미널 pane을 따라가는 중입니다"
        case .held: return "패널이 최전면이 아니라 마지막으로 확인한 대상을 표시합니다"
        case .locked: return "사용자가 고정했습니다. 해제하면 현재 포커스를 다시 확인합니다"
        case .pending: return "아직 실행할 대상을 확인하지 못했습니다"
        case .error: return "조회에 실패했거나 경로를 사용할 수 없습니다"
        }
    }
}

// MARK: - 상세 보기

/// 평소 Dock에 두지 않는 **진단 정보**를 모아 보여준다.
///
/// 숨기기·종료·링크 전체 목록처럼 바에 다 놓을 수 없는 항목도 여기서 접근한다.
/// 없는 설정을 암시하는 버튼은 두지 않는다.
struct DockDetailsView: View {
    @ObservedObject var model: DockModel
    let availableWidth: CGFloat

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                Divider()
                identityGrid
                if let detail = model.state.detail {
                    labeled("사유", detail, color: .red)
                }
                if let previous = model.state.previousPath {
                    labeled("이전 위치", previous)
                }
                if let message = model.actionMessage {
                    labeled("결과", message)
                }
                if let notice = model.catalogNotice {
                    labeled("프로젝트 설정", notice, color: notice.contains("실패") ? .red : .orange)
                }
                if let notice = model.settingsNotice {
                    labeled("설정 파일", notice, color: .orange)
                }
                displaySection
                itemSection
                Divider()
                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("상세 정보").font(.subheadline).bold()
            Spacer()
            Button(action: { model.hideDetails() }) {
                Label("닫기", systemImage: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("상세 보기를 닫습니다 (Esc)")
            .onHover { model.setHover($0 ? .details : nil) }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        model.focusedItem == .details ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
        }
    }

    /// 전체 경로·식별자·연결 상태. 바에서는 보여주지 않는 값들이다.
    private var identityGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            labeled("전체 경로", model.state.fullPath ?? "-", selectable: true)
            HStack(spacing: 16) {
                small("호스트", model.state.hostAppID ?? "-")
                small("Adapter", model.state.adapterID ?? "-")
                small("연결", connectionText)
            }
            HStack(spacing: 16) {
                small("pane", model.state.paneID.map { String($0.prefix(8)) } ?? "-")
                small("포커스", focusText)
                small("확인", model.state.observedAt.map { Self.timeFormatter.string(from: $0) } ?? "-")
            }
            small("경로 출처", model.state.cwdSource ?? "-")
            // 실행 중인 빌드(제품 버전 · 빌드 번호 · 커밋 · 작업 트리 상태).
            small("빌드", model.build.displayText)
        }
    }

    /// 표시 목록·배치 상태. **화면에 그린 수와 밀린 수를 같은 출처에서** 보여준다.
    @ViewBuilder
    private var displaySection: some View {
        Divider()
        HStack(spacing: 16) {
            small("표시", "\(model.display.visibleItemCount)개")
            small("숨김", "\(model.display.hiddenItemCount)개")
            small("영역 폭", "\(Int(model.display.projectAreaWidth))pt")
            small("바 폭", "\(Int(model.display.barWidth))pt")
        }
        small(
            "배치",
            model.effectiveLayout.order.map(\.label).joined(separator: " → ")
                + " · 카드 \(model.display.visibleCards.count)/\(model.effectiveLayout.cards.count)개"
                + (model.display.cardHidden > 0 ? " (밀림 \(model.display.cardHidden))" : "")
        )
        cardSection
        if model.display.isSpaceShort {
            labeled(
                "공간 부족",
                "배치가 화면보다 \(Int(model.display.demandWidth - model.display.barWidth))pt 넓어 프로젝트 영역을 \(Int(model.display.projectAreaWidth))pt로 줄였습니다. "
                    + "밀린 항목은 위 목록과 편집기에서 확인할 수 있습니다.",
                color: .orange,
                selectable: false
            )
        }
        if model.display.hiddenItemCount > 0 {
            labeled(
                "밀린 항목",
                hiddenItemSummary,
                color: .orange,
                selectable: false
            )
        }
    }

    private var hiddenItemSummary: String {
        var parts: [String] = []
        if model.display.commonHidden > 0 { parts.append("공통 \(model.display.commonHidden)개") }
        if model.display.projectHidden > 0 { parts.append("프로젝트 \(model.display.projectHidden)개") }
        let names = model.resolution.allItems
            .filter { target in !model.display.order.contains { $0.ref == target.ref } }
            .map(\.name)
        return parts.joined(separator: " · ") + (names.isEmpty ? "" : " — \(names.joined(separator: ", "))")
    }

    /// 카드 목록과 **조작**. 밀린 카드도 여기서 시작·일시정지·재설정할 수 있다(같은 id·같은 실행 경로).
    @ViewBuilder
    private var cardSection: some View {
        if !model.effectiveLayout.cards.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("카드").font(.caption2).foregroundStyle(.secondary)
                    Text("\(model.effectiveLayout.cards.count)개").font(.caption2)
                    if model.display.cardHidden > 0 {
                        Text("· 밀림 \(model.display.cardHidden)").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                }
                ForEach(model.effectiveLayout.cards) { card in
                    cardRow(card)
                }
            }
        }
    }

    private func cardRow(_ card: DockCardSpec) -> some View {
        let shown = model.display.visibleCards.contains { $0.id == card.id }
        let state = model.timerState(for: card.id)
        return HStack(spacing: 6) {
            Text(card.kind.label).font(.caption2).foregroundStyle(.secondary)
            if card.kind == .focusTimer {
                Text(state.text(at: model.now)).font(.caption).monospacedDigit()
                Text(state.statusText(at: model.now))
                    .font(.caption2)
                    .foregroundStyle(state.isFinished(at: model.now) ? .orange : .secondary)
            }
            if !shown {
                Text("밀림").font(.caption2).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if card.kind == .focusTimer {
                ForEach(DockTimerAction.allCases, id: \.self) { action in
                    cardControl(card.id, action: action, state: state)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }

    /// 카드 조작 버튼(마우스·키보드가 같은 `performTimer` 경로를 쓴다).
    private func cardControl(_ cardID: String, action: DockTimerAction, state: FocusTimerState) -> some View {
        let focus = DockFocusControl.timer(cardID: cardID, action: action)
        let isOn: Bool = {
            switch action {
            case .start: return state.isRunning(at: model.now)
            case .pause: return !state.isRunning(at: model.now) && !state.isFinished(at: model.now) && state.elapsed(at: model.now) > 0
            case .reset: return false
            }
        }()
        let ended = state.isFinished(at: model.now)
        return Button(action: { model.performTimer(action, cardID: cardID, source: .mouse) }) {
            Label(
                action == .start && ended ? "다시 시작" : action.label,
                systemImage: action == .start ? (ended ? "arrow.clockwise" : "play.fill")
                    : (action == .pause ? "pause.fill" : "arrow.counterclockwise")
            )
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.green.opacity(0.22) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        model.focusedItem == focus ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: model.focusedItem == focus ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(cardID) — \(action.label)")
        .accessibilityLabel("\(cardID) \(action.label)")
    }

    private var connectionText: String {
        guard let info = model.state.connectionStatus else { return "-" }
        switch info {
        case .connected: return "connected"
        case .unavailable: return "unavailable"
        case .refused: return "refused"
        case .denied: return "denied"
        case .incompatible: return "incompatible"
        }
    }

    private var focusText: String {
        guard let frontmost = model.state.hostFrontmost else { return "확인 불가" }
        return frontmost ? "최전면" : "비활성"
    }

    /// 등록한 항목 전체. 바에서 밀린 항목도 **여기서는 전부** 접근할 수 있다.
    @ViewBuilder
    private var itemSection: some View {
        Divider()
        HStack(spacing: 6) {
            Text("항목").font(.caption2).foregroundStyle(.secondary)
            Text("공통 \(model.resolution.commonItems.count)개").font(.caption2)
            if model.resolution.hasProject {
                Text("· \(model.resolution.projectName) \(model.resolution.projectItems.count)개")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dock 편집…") { model.openEditor() }
                .buttonStyle(.bordered)
                .help("앱·폴더·링크를 추가하고 배치·순서를 바꿉니다")
        }
        if model.resolution.hasProject {
            labeled("프로젝트", model.resolution.projectName, selectable: false)
            labeled("기준 폴더", model.resolution.projectRoot)
        }
        ForEach(model.resolution.allItems, id: \.ref) { item in
            if item.isCommon || detailsPanelStatus == .registered || detailsPanelStatus == .unregistered {
                itemRow(item)
            } else {
                // 지금은 실행할 수 없는 프로젝트 항목 — **참고 정보로만** 보여준다(누를 수 있는 행이 아니다).
                itemReferenceRow(item)
            }
        }
        if detailsPanelStatus == .pending || detailsPanelStatus == .failure {
            labeled(
                "프로젝트 항목",
                detailsPanelStatus == .pending
                    ? "경로를 확인하는 중이라 실행할 수 없습니다. 공통 앱·카드는 그대로 쓸 수 있습니다."
                    : "작업 상태가 오류라 프로젝트 항목을 실행할 수 없습니다: \(model.state.detail ?? "조회 실패")",
                color: .orange,
                selectable: false
            )
        }
        if !model.resolution.diagnostics.isEmpty {
            labeled("프로젝트 경고", model.resolution.diagnostics.prefix(2).joined(separator: "\n"), color: .orange)
        }
    }

    /// 상세 보기의 판정도 패널과 **같은 함수**를 쓴다.
    private var detailsPanelStatus: DockPanelStatus {
        DockPanelStatus.from(state: model.state, hasProject: model.display.projectRegistered)
    }

    /// 지금 실행할 수 없는 프로젝트 항목의 **참고 행**(버튼 아님 · hover/선택 없음).
    private func itemReferenceRow(_ item: DockItemTarget) -> some View {
        HStack(spacing: 6) {
            if item.kind == .app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.target))
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: itemSymbol(for: item.kind)).font(.caption2)
            }
            Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("프로젝트").font(.caption2).foregroundStyle(.tertiary)
            Text(item.target).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
        .help("지금은 실행할 수 없습니다 — 프로젝트 항목은 작업 상태가 정상일 때만 실행됩니다")
        .accessibilityLabel("참고 항목 \(item.name) — 지금은 실행할 수 없습니다")
    }

    private func itemRow(_ item: DockItemTarget) -> some View {
        let ref = item.ref
        let isShown = model.display.order.contains { $0.ref == ref }
        return Button(action: { model.performItem(ref: ref, source: .mouse) }) {
            HStack(spacing: 6) {
                if item.kind == .app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.target))
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: itemSymbol(for: item.kind)).font(.caption2)
                }
                Text(item.name).font(.caption).bold().lineLimit(1)
                Text(item.isCommon ? "공통" : "프로젝트")
                    .font(.caption2).foregroundStyle(.secondary)
                if !isShown {
                    // 바에서 밀린 항목임을 숨기지 않는다.
                    Text("바에서 밀림").font(.caption2).foregroundStyle(.orange)
                }
                Text(item.target).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(model.hoveredItem == .item(ref) ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(model.focusedItem == .item(ref) ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.setHover(inside ? .item(ref) : (model.hoveredItem == .item(ref) ? nil : model.hoveredItem))
        }
        .help(itemHelp(for: item))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Tab 이동 · Enter 실행 · Esc 닫기 · ⌃⌥⌘D 호출")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            Button("숨기기") { model.hideWindow() }
                .buttonStyle(.bordered)
                .help("Dock을 숨깁니다. ⌃⌥⌘D로 다시 부를 수 있습니다")
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered)
                .help("PaneDock을 종료합니다")
        }
    }

    /// 진단 값은 **항상 선택·복사할 수 있게** 둔다(오류 문구를 그대로 옮길 수 있어야 한다).
    private func labeled(_ title: String, _ value: String, color: Color = .secondary, selectable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(color == .secondary ? Color.primary : color)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func small(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2).lineLimit(1).truncationMode(.middle)
        }
    }
}
