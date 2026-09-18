/// 항목 종류별 기호(앱 아이콘을 못 읽었을 때의 대체).
private func itemSymbol(for kind: DockItemKind) -> String {
    switch kind {
    case .app: return "app"
    case .folder: return "folder"
    case .link: return "link"
    }
}

/// 앱 항목의 실제 아이콘. 폴더·링크는 기호로 구분한다.
private func itemIconImage(for item: DockItemTarget) -> NSImage? {
    guard item.kind == .app else { return nil }
    let image = NSWorkspace.shared.icon(forFile: item.target)
    // 실제 앱 아이콘을 **그대로** 그린다(단색 템플릿으로 바뀌면 앱을 알아볼 수 없다).
    image.isTemplate = false
    image.size = NSSize(width: 16, height: 16)
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

/// 가로형 Dock 바 + 상세 보기.
///
/// ## 화면 규칙
///
/// - **상태는 색만으로 전달하지 않는다.** 항상 아이콘과 한국어 이름을 함께 보여준다.
/// - 평소에는 **프로젝트/폴더 이름·소스·짧은 상태**만 보여주고,
///   전체 경로·pane ID·경로 출처·연결 상태·상세 사유는 **상세 보기**로 보낸다.
/// - 오류를 숨기는 것이 목적이 아니다. 확인 불가·오류는 바에서 즉시 보이고,
///   선택하면 구체적인 이유를 볼 수 있다.
/// - 긴 이름은 줄여 표시하고 **툴팁과 상세 보기**로 전체 값을 확인할 수 있다.
/// - 인라인으로 다 못 보여주는 링크는 "+N"으로 알리고 상세 보기에 **전부** 나열한다.
///
/// ## 조작
///
/// 모든 버튼은 기존 실제 기능(`DockModel`)에 연결돼 있다. 동작 없는 항목은 만들지 않는다.
/// 마우스와 키보드가 같은 검증 경로를 쓴다. hover와 키보드 선택은 다르게 표시한다.
struct DockView: View {
    @ObservedObject var model: DockModel

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var availableWidth: CGFloat {
        ScreenGeometry.fallbackFrame.width
    }

    private var visibleItemCount: Int {
        DockBarLayout.linkBudget(
            total: model.resolution.allItems.count,
            availableWidth: availableWidth
        ).visible
    }

    /// 공통 항목과 프로젝트 항목의 경계(구분선을 넣을 위치).
    private var commonItemCount: Int {
        model.resolution.commonItems.count
    }

    /// 인라인에서 밀린 항목 수(조용히 자르지 않고 "+N"으로 알린다).
    private var hiddenItemCount: Int {
        // 표시 수는 모델이 배치(프로젝트 영역 폭)로 정한다 → 여기서 다시 계산하지 않는다.
        max(0, model.resolution.allItems.count - model.visibleItemCount)
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
        .help("Dock이 접혀 있습니다 — 마우스를 올리면 펼쳐집니다")
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

    // MARK: - 바

    private var bar: some View {
        HStack(spacing: 10) {
            stateBadge

            if model.isFake {
                // 창 제목 표시줄이 없어졌으므로 가짜 모드 표시를 바 안에 둔다.
                // 압축되지 않게 고정하고, 대비를 확실히 준다(회색 배경 위 붉은 글씨는 읽히지 않았다).
                Text("FAKE")
                    .font(.caption2).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                    .help("가짜 데이터 모드입니다. 실제 터미널에 연결되지 않았습니다")
                    .accessibilityLabel("가짜 데이터 모드")
            }

            identityBlock

            if !model.items(forInline: visibleItemCount).isEmpty {
                separator
                itemChips
            }

            Spacer(minLength: 6)

            separator
            actionCluster
        }
        .padding(.horizontal, 14)
        .frame(height: model.effectiveAppearance.size.barHeight)
        // 빈 영역에서만 창을 끌 수 있다. 버튼 위에서는 클릭이 그대로 동작한다.
        .background(WindowDragHandle())
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 34)
    }

    /// 상태를 **아이콘 + 한국어 이름**으로 보여준다(색만으로 구분하지 않는다).
    /// 상태 표시는 **작게** — 색만으로 구분하지 않는다는 규칙은 툴팁·접근성 이름과 상세 보기가 지킨다.
    /// (승인된 배치: 큰 진단 배지 대신 작은 점)
    private var stateBadge: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(stateColor.opacity(0.35), lineWidth: 3).padding(-3))
            .help(shortStatusHelp)
            .accessibilityLabel("상태: \(stateLabel)")
    }

    /// 현재 프로젝트/폴더 이름과 소스·짧은 상태.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(primaryTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(primaryTitleHelp)
                .accessibilityLabel("대상: \(primaryTitle)")

            Text(secondaryLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(secondaryLineHelp)
        }
        .frame(minWidth: DockBarLayout.projectAreaMinimumWidth, alignment: .leading)
        // 이름 영역이 먼저 줄어들고(줄임 표시), 칩은 크기를 지킨다.
        .layoutPriority(0)
    }

    /// 등록한 항목(공통 → 프로젝트). 앱은 실제 앱 아이콘, 폴더·링크는 구분되는 기호를 쓴다.
    private var itemChips: some View {
        HStack(spacing: 6) {
            ForEach(model.items(forInline: visibleItemCount)) { entry in
                if entry.index == commonItemCount, commonItemCount > 0 {
                    // 공통 항목과 프로젝트 항목의 경계.
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 26)
                }
                chip(
                    icon: itemSymbol(for: entry.item.kind),
                    image: itemIconImage(for: entry.item),
                    label: entry.item.name,
                    item: .item(entry.index),
                    // 아이콘 중심 모드는 **등록 항목의 라벨만** 줄인다. 툴팁·접근성 이름은 남긴다.
                    showsLabel: model.effectiveAppearance.labelMode.showsItemLabels,
                    help: itemHelp(for: entry.item),
                    action: { model.performItem(at: entry.index, source: .mouse) }
                )
            }
            if hiddenItemCount > 0 {
                chip(
                    icon: "ellipsis",
                    label: "+\\(hiddenItemCount)",
                    item: .more,
                    help: "표시하지 못한 항목 \\(hiddenItemCount)개. 더보기에서 전부 확인할 수 있습니다.",
                    action: { model.showDetails() }
                )
            }
        }
    }

    /// 보조 동작은 **작은 ⋯ 메뉴**로 접는다(승인된 배치).
    /// 열기·복사·잠금은 초점 목록에서도 빠져 있어 화면과 키보드가 어긋나지 않는다.
    /// "더보기"는 화면에 남겨 키보드 초점의 시각 앵커로 쓴다.
    private var actionCluster: some View {
        HStack(spacing: 6) {
            Menu {
                Button("현재 폴더 열기") { model.perform(.openFolder, source: .mouse) }
                    .disabled(!model.state.canOpenFolder)
                Button("현재 경로 복사") { model.perform(.copyPath, source: .mouse) }
                    .disabled(!model.state.canCopyPath)
                Divider()
                Button(model.state.isLocked ? "고정 해제" : "표시 대상 고정") { model.toggleLock() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("보조 동작: 현재 폴더 열기 · 경로 복사 · 표시 대상 고정")
            .accessibilityLabel("보조 동작 메뉴")

            chip(
                icon: "ellipsis.circle",
                label: "더보기",
                item: model.isDetailsVisible ? .detailsClose : .more,
                help: model.isDetailsVisible ? "상세 보기를 닫습니다 (Esc)" : "경로·pane·연결 상태 등 상세 정보",
                action: { model.toggleDetails() }
            )
        }
    }

    /// 바에서 쓰는 공통 칩. 링크와 동작 버튼이 **같은 모양·같은 표시 규칙**을 쓴다.
    private func chip(
        icon: String,
        image: NSImage? = nil,
        label: String,
        item: DockModel.FocusItem,
        enabled: Bool = true,
        showsLabel: Bool = true,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let image {
                    Image(nsImage: image).frame(width: 30, height: 30)
                } else {
                    Image(systemName: icon).font(.system(size: 22, weight: .medium))
                }
                if showsLabel {
                    Text(label).font(.caption).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, model.effectiveAppearance.size.chipVerticalPadding)
            // 칩은 **압축되지 않게** 고정한다. 압축되면 라벨이 사라져 아이콘만 남는다.
            // 넘치는 링크는 인라인 수를 줄이고 "+N"으로 알린다.
            .fixedSize(horizontal: true, vertical: false)
            .background(fill(for: item))
            .overlay(focusRing(for: item))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in
            // 벗어날 때는 **다른 항목으로 옮겨간 경우**를 덮어쓰지 않는다.
            model.setHover(inside ? item : (model.hoveredItem == item ? nil : model.hoveredItem))
        }
        .help(help)
        .accessibilityLabel(help)
    }

    /// hover는 옅은 채움, 키보드 선택은 테두리. 두 상태를 **다르게** 보여준다.
    private func fill(for item: DockModel.FocusItem) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(model.hoveredItem == item ? 0.12 : 0.05))
    }

    @ViewBuilder
    private func focusRing(for item: DockModel.FocusItem) -> some View {
        if model.focusedItem == item {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        }
    }

    // MARK: - 문구

    /// 프로젝트가 잡히면 프로젝트 이름, 아니면 폴더 이름.
    private var primaryTitle: String {
        if model.resolution.hasProject { return model.resolution.projectName }
        if model.state.fullPath != nil { return model.state.folderName }
        return "대상 확인 중"
    }

    private var primaryTitleHelp: String {
        if model.resolution.hasProject {
            return "프로젝트: \(model.resolution.projectName) (기준 폴더 \(model.resolution.projectRoot))"
        }
        return model.state.fullPath ?? "아직 대상을 확인하지 못했습니다"
    }

    /// 소스·짧은 상태. 상세 정보는 상세 보기로 보낸다.
    ///
    /// **아이콘 중심 모드에서 마우스를 올린 항목은 이름을 여기에 띄운다.**
    /// 라벨을 숨긴 항목을 확인할 수 있는 수단이다(툴팁과 함께 제공).
    private var secondaryLine: String {
        if !model.effectiveAppearance.labelMode.showsItemLabels,
           case .item(let index) = model.hoveredItem,
           model.resolution.allItems.indices.contains(index) {
            let item = model.resolution.allItems[index]
            return "\(item.kind.label) · \(item.name)"
        }
        var parts: [String] = []
        if let host = model.state.hostAppID { parts.append(host) }
        if let folder = model.state.fullPath.map(URL.init(fileURLWithPath:)) {
            parts.append(folder.lastPathComponent)
        }
        if model.isFake { parts.append("[FAKE]") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var secondaryLineHelp: String {
        var lines: [String] = []
        if let host = model.state.hostAppID { lines.append("추적 소스: \(host)") }
        if let path = model.state.fullPath { lines.append("경로: \(path)") }
        if let detail = model.state.detail { lines.append(detail) }
        return lines.isEmpty ? "정보 없음" : lines.joined(separator: "\n")
    }

    private var stateLabel: String {
        switch model.state.display {
        case .tracked: return "추적 중"
        case .held: return "유지 중"
        case .locked: return "잠금"
        case .pending: return "확인 중"
        case .error: return "오류"
        }
    }

    private var stateSymbol: String {
        switch model.state.display {
        case .tracked: return "scope"
        case .held: return "pause.circle"
        case .locked: return "lock.fill"
        case .pending: return "clock"
        case .error: return "exclamationmark.triangle.fill"
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

    private var openHelp: String {
        model.state.canOpenFolder
            ? "현재 폴더를 Finder로 엽니다 — \(model.state.fullPath ?? "-")"
            : "지금은 열 수 없습니다: \(model.state.detail ?? "실행할 대상을 확인하는 중입니다")"
    }

    private var copyHelp: String {
        model.state.canCopyPath
            ? "현재 경로를 클립보드로 복사합니다 — \(model.state.fullPath ?? "-")"
            : "지금은 복사할 수 없습니다: \(model.state.detail ?? "실행할 대상을 확인하는 중입니다")"
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
            .onHover { model.setHover($0 ? .detailsClose : nil) }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        model.focusedItem == .detailsClose ? Color.accentColor : .clear,
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
        }
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

    /// 등록한 항목 전체. 바에서 "+N"으로 밀린 항목도 **여기서는 전부** 접근할 수 있다.
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
            Button("Dock 편집…") { model.onOpenEditor?() }
                .buttonStyle(.bordered)
                .help("앱·폴더·링크를 추가하고 순서를 바꿉니다")
        }
        if model.resolution.hasProject {
            labeled("프로젝트", model.resolution.projectName, selectable: false)
            labeled("기준 폴더", model.resolution.projectRoot)
        }
        ForEach(Array(model.resolution.allItems.enumerated()), id: \.element.itemID) { index, item in
            itemRow(item, index: index)
        }
        if !model.resolution.diagnostics.isEmpty {
            labeled("프로젝트 경고", model.resolution.diagnostics.prefix(2).joined(separator: "\n"), color: .orange)
        }
    }

    private func itemRow(_ item: DockItemTarget, index: Int) -> some View {
        Button(action: { model.performItem(at: index, source: .mouse) }) {
            HStack(spacing: 6) {
                if item.kind == .app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.target))
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: itemSymbol(for: item.kind)).font(.caption2)
                }
                Text(item.name).font(.caption).bold().lineLimit(1)
                Text(item.isCommon ? "공통" : "프로젝트")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(item.target).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(model.hoveredItem == .item(index) ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(model.focusedItem == .item(index) ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            model.setHover(inside ? .item(index) : (model.hoveredItem == .item(index) ? nil : model.hoveredItem))
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
