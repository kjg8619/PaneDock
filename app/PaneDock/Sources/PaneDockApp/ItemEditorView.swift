import AppKit
import FocusProbeCore
import SwiftUI
import UniformTypeIdentifiers

/// Dock 항목 편집창. **별도 창**이다(작은 Dock 안에 폼을 넣지 않는다).
///
/// - 초안으로 작업한다. **저장을 누르기 전에는 실제 설정과 Dock 구성이 바뀌지 않는다.**
/// - 편집 대상은 열 때 정해지고, 터미널 포커스가 바뀌어도 자동으로 바뀌지 않는다(헤더에 명시).
/// - SwiftUI `@State`를 쓸 수 없는 환경이라 선택·폼 상태는 `DockModel`이 들고 있다.
/// 실제 앱 아이콘(템플릿 아님). 없으면 nil이라 기호로 대체한다.
func appIcon(forFile path: String) -> NSImage {
    let image = NSWorkspace.shared.icon(forFile: path)
    image.isTemplate = false
    image.size = NSSize(width: 16, height: 16)
    return image
}

struct ItemEditorView: View {
    @ObservedObject var model: DockModel

    private var draft: ProjectCatalogDraft? { model.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            // 가운데(편집 대상·항목·배치·모양)만 스크롤한다.
            // **저장·취소는 항상 보여야 한다** — 창이 작을 때 푸터가 잘리면 저장할 수 없다(V18.5에서 화면으로 확인).
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let draft {
                        HStack(alignment: .top, spacing: 14) {
                            scopeColumn(draft)
                            Divider().frame(height: 320)
                            itemColumn(draft)
                        }
                    } else {
                        Text("편집 중인 초안이 없습니다.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    layoutSection
                    Divider()
                    appearanceSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 560, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                Text("Dock 편집").font(.headline)
                Spacer()
                if let draft, draft.isDirty {
                    Text("저장하지 않은 변경 있음")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            // **편집 중인 대상을 명확히** 보여준다(자동으로 바뀌지 않는다는 것을 알 수 있게).
            if let draft {
                Text("편집 중: \(draft.scopeTitle(draft.scope))")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("편집 중인 대상: \(draft.scopeTitle(draft.scope))")
            }
            Text("변경은 저장을 눌러야 반영됩니다. 취소하면 아무것도 바뀌지 않습니다.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 범위(공통 / 프로젝트)

    private func scopeColumn(_ draft: ProjectCatalogDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("편집 대상").font(.caption).bold()
            Button(action: { model.selectEditingScope(.common) }) {
                scopeRow("공통 (모든 프로젝트)", count: draft.catalog.common.count, selected: draft.scope == .common)
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(draft.projects, id: \.id) { project in
                        Button(action: { model.selectEditingScope(.project(id: project.id)) }) {
                            scopeRow(project.name, count: project.items.count, selected: draft.scope == .project(id: project.id))
                        }
                        .buttonStyle(.plain)
                        .help("기준 폴더 \(project.root)")
                    }
                }
            }
            .frame(height: 150)

            Divider()
            Text("새 프로젝트").font(.caption2).foregroundStyle(.secondary)
            TextField("이름", text: Binding(
                get: { model.newProjectName },
                set: { model.editorUpdateNewProject(name: $0) }
            ))
            HStack(spacing: 6) {
                Text(model.newProjectRoot.isEmpty ? "(기준 폴더 선택)" : model.newProjectRoot)
                    .font(.caption2).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(model.newProjectRoot.isEmpty ? .secondary : .primary)
                Button("선택…") { model.pickNewProjectRoot() }
                    .buttonStyle(.bordered)
                Button("추가") { model.commitNewProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.newProjectName.trimmingCharacters(in: .whitespaces).isEmpty || model.newProjectRoot.isEmpty)
            }
        }
        .frame(width: 260, alignment: .leading)
    }

    private func scopeRow(_ title: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: selected ? "smallcircle.filled.circle" : "circle").font(.caption2)
            Text(title).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.10 : 0.03)))
    }

    // MARK: - 항목 목록 + 폼

    private func itemColumn(_ draft: ProjectCatalogDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("항목 \(draft.items.count)개").font(.caption).bold()
                Button("항목 추가") { model.editorBeginAdd() }
                    .buttonStyle(.bordered)
                if let selected = model.editorSelection {
                    Button("↑") { model.editorMove(selected, by: -1) }.buttonStyle(.bordered)
                        .help("한 칸 위로")
                    Button("↓") { model.editorMove(selected, by: 1) }.buttonStyle(.bordered)
                        .help("한 칸 아래로")
                    Button("편집") { model.editorBeginEdit(selected) }.buttonStyle(.bordered)
                    Button("삭제") { model.editorRemove(selected) }.buttonStyle(.bordered)
                        .help("Dock에서만 뺍니다. 앱·폴더·원본 파일은 지우지 않습니다")
                }
                Spacer()
                Text("드래그하거나 ↑↓로 순서를 바꿉니다")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                        itemRow(item, index: index)
                    }
                }
            }
            .frame(height: 190)

            Divider()
            itemForm
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemRow(_ item: DockItem, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.tertiary)
            if item.kind == .app {
                Image(nsImage: appIcon(forFile: item.target)).frame(width: 16, height: 16)
            } else {
                Image(systemName: item.kind == .folder ? "folder" : "link").font(.caption2)
            }
            Text(item.name.isEmpty ? "(이름 없음)" : item.name).font(.caption).bold().lineLimit(1)
            Text(item.kind.label).font(.caption2).foregroundStyle(.secondary)
            Text(item.target).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(model.editorSelection == item.id ? 0.12 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(model.editorSelection == item.id ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        // 실행은 클릭이 아니라 **선택**만 한다(편집 중에는 실행하지 않는다).
        .onTapGesture { model.editorSelect(item.id) }
        // 행을 AX로 찾을 수 있게 라벨을 준다(순서 확인 + 보조기술 접근).
        .accessibilityLabel("항목 \(index + 1) \(item.kind.label) \(item.name)")
        .accessibilityIdentifier("editor-row-\(index)")
        .onDrag {
            model.editorBeginDrag(item.id)
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: ItemDropDelegate(model: model, targetIndex: index))
        .help("\(item.kind.label) · \(item.target)")
    }

    private var itemForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.editorForm.isPresented {
                HStack(spacing: 8) {
                    Picker("종류", selection: Binding(
                        get: { model.editorForm.kind },
                        set: { model.editorUpdateForm(kind: $0) }
                    )) {
                        ForEach(DockItemKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    TextField("이름", text: Binding(
                        get: { model.editorForm.name },
                        set: { model.editorUpdateForm(name: $0) }
                    ))
                    .frame(width: 150)
                }
                HStack(spacing: 8) {
                    TextField(targetPlaceholder, text: Binding(
                        get: { model.editorForm.target },
                        set: { model.editorUpdateForm(target: $0) }
                    ))
                    if model.editorForm.kind != .link {
                        Button("파일 선택…") { model.pickTargetForForm() }
                            .buttonStyle(.bordered)
                    }
                    Button(model.editorForm.editingID == nil ? "추가" : "적용") { model.editorCommitForm() }
                        .buttonStyle(.borderedProminent)
                    Button("닫기") { model.editorCancelForm() }
                        .buttonStyle(.bordered)
                }
                Text(formHint).font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("항목을 추가하거나 목록에서 골라 편집하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var targetPlaceholder: String {
        switch model.editorForm.kind {
        case .app: return "/Applications/앱.app"
        case .folder: return "/Users/me/Projects/폴더"
        case .link: return "https://example.com"
        }
    }

    private var formHint: String {
        switch model.editorForm.kind {
        case .app: return "설치된 .app 번들을 고릅니다. 실행은 일반적인 앱 열기까지만 합니다."
        case .folder: return "고정 폴더를 등록합니다. 현재 폴더 열기와는 다른 항목입니다."
        case .link: return "http 또는 https 주소만 등록됩니다."
        }
    }

    // MARK: - 모양 (항목 편집과 구분되는 영역)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush")
                Text("모양").font(.caption).bold()
                Text("바꾸면 Dock에 바로 보입니다. 저장을 눌러야 유지됩니다.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            // 두 방식의 차이(화면 가장자리 자동 숨김 vs 이 자리에서 접기)를 UI에서 분명히 말한다.
            Text(model.effectiveAppearance.displayMode.summary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // 선택기가 4개라 한 줄에 넣으면 창 밖으로 나간다 → 두 줄로 나눈다.
            VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                appearancePicker(
                    "크기",
                    selection: appearanceBinding(\.size, set: { value in
                        var next = model.effectiveAppearance
                        next.size = value
                        model.previewAppearanceChange(next)
                    }),
                    options: DockSizeSetting.allCases,
                    titleFor: { $0.label }
                )
                appearancePicker(
                    "항목 표시",
                    selection: appearanceBinding(\.labelMode, set: { value in
                        var next = model.effectiveAppearance
                        next.labelMode = value
                        model.previewAppearanceChange(next)
                    }),
                    options: DockLabelMode.allCases,
                    titleFor: { $0.label }
                )
                appearancePicker(
                    "표시 모드",
                    selection: appearanceBinding(\.displayMode, set: { value in
                        var next = model.effectiveAppearance
                        next.displayMode = value
                        model.previewAppearanceChange(next)
                    }),
                    options: DockDisplayMode.allCases,
                    titleFor: { $0.label }
                )
            }
            HStack(spacing: 16) {
                appearancePicker(
                    "색상 모드",
                    selection: appearanceBinding(\.colorMode, set: { value in
                        var next = model.effectiveAppearance
                        next.colorMode = value
                        model.previewAppearanceChange(next)
                    }),
                    options: DockColorMode.allCases,
                    titleFor: { $0.label }
                )
            }
            }
        }
    }

    private func appearanceBinding<T: Hashable>(
        _ get: @escaping (DockAppearance) -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(get: { get(model.effectiveAppearance) }, set: set)
    }

    private func appearancePicker<T: Hashable>(
        _ title: String,
        selection: Binding<T>,
        options: [T],
        titleFor: @escaping (T) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(titleFor(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()
        }
    }

    // MARK: - 배치 (순서·영역 폭·카드 — 저장 전에는 미리보기)

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group")
                Text("배치").font(.caption).bold()
                Text("바꾸면 Dock에 바로 보입니다. 저장을 눌러야 유지됩니다.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if model.layoutIsDirty {
                    Text("저장하지 않은 배치 변경")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            DockLayoutPreview(model: model)
            HStack(alignment: .top, spacing: 18) {
                layoutOrderControls
                layoutWidthControls
                layoutCardControls
            }
        }
    }

    /// 공통·카드·프로젝트 영역의 순서. 화면에 보이는 순서를 그대로 바꾼다.
    private var layoutOrderControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("순서").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(model.effectiveLayout.order.enumerated()), id: \.element) { index, component in
                HStack(spacing: 5) {
                    Text("\(index + 1). \(component.label)").font(.caption).frame(width: 120, alignment: .leading)
                    Button("↑") { model.editorMoveComponent(component, by: -1) }
                        .buttonStyle(.bordered)
                        .disabled(index == 0)
                        .help("\(component.label) 구역을 한 칸 앞으로")
                    Button("↓") { model.editorMoveComponent(component, by: 1) }
                        .buttonStyle(.bordered)
                        .disabled(index == model.effectiveLayout.order.count - 1)
                        .help("\(component.label) 구역을 한 칸 뒤로")
                }
            }
        }
        .frame(width: 230, alignment: .leading)
    }

    /// 프로젝트 영역 폭. **항목 수와 무관하게 유지되는 값**이다.
    private var layoutWidthControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("프로젝트 영역 폭").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("−") { model.editorSetProjectAreaWidth(model.effectiveLayout.projectAreaWidth - 20) }
                    .buttonStyle(.bordered)
                    .disabled(model.effectiveLayout.projectAreaWidth <= DockLayout.minimumProjectAreaWidth)
                    .help("영역 폭을 20pt 줄입니다")
                Slider(
                    value: Binding(
                        get: { model.effectiveLayout.projectAreaWidth },
                        set: { model.editorSetProjectAreaWidth($0) }
                    ),
                    in: DockLayout.minimumProjectAreaWidth...DockLayout.maximumProjectAreaWidth,
                    step: 20
                )
                .frame(width: 120)
                Button("＋") { model.editorSetProjectAreaWidth(model.effectiveLayout.projectAreaWidth + 20) }
                    .buttonStyle(.bordered)
                    .disabled(model.effectiveLayout.projectAreaWidth >= DockLayout.maximumProjectAreaWidth)
                    .help("영역 폭을 20pt 늘립니다")
                Text("\(Int(model.effectiveLayout.projectAreaWidth))pt")
                    .font(.caption).monospacedDigit()
                    .frame(width: 48, alignment: .leading)
            }
            Text("항목이 많아도 이 폭은 그대로이고, 넘치는 항목은 영역 안에서 `+N`으로 밀립니다.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if model.display.isSpaceShort {
                Text("지금 배치가 화면보다 넓어 영역이 \(Int(model.display.projectAreaWidth))pt로 줄어 있습니다.")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 240, alignment: .leading)
    }

    /// 카드 추가·제거·순서. 같은 종류를 여러 개 두어도 id로 구분한다.
    private var layoutCardControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("카드").font(.caption2).foregroundStyle(.secondary)
                ForEach(DockCardKind.allCases, id: \.self) { kind in
                    Button("\(kind.label) 추가") { model.editorAddCard(kind) }
                        .buttonStyle(.bordered)
                }
            }
            if model.effectiveLayout.cards.isEmpty {
                Text("카드가 없습니다. 추가하면 바의 카드 구역에 나타납니다.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(Array(model.effectiveLayout.cards.enumerated()), id: \.element.id) { index, card in
                HStack(spacing: 5) {
                    Text("\(card.kind.label) (\(card.id))").font(.caption).frame(width: 150, alignment: .leading)
                    Button("↑") { model.editorMoveCard(card.id, by: -1) }
                        .buttonStyle(.bordered)
                        .disabled(index == 0)
                    Button("↓") { model.editorMoveCard(card.id, by: 1) }
                        .buttonStyle(.bordered)
                        .disabled(index == model.effectiveLayout.cards.count - 1)
                    Button("제거") { model.editorRemoveCard(card.id) }
                        .buttonStyle(.bordered)
                        .help("카드를 바에서 뺍니다. 실행 중이던 타이머 상태는 앱이 실행 중인 동안 유지됩니다")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 푸터

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = model.editorNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(notice.contains("저장했습니다") ? .green : .red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let draft, draft.requiresFormatMigration {
                Text("저장하면 파일 형식이 v2로 바뀝니다. 원본은 백업됩니다.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            Button("저장") { model.saveAll() }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft == nil && !model.layoutIsDirty && model.previewAppearance == nil)
                .help("편집한 구성·배치·모양을 디스크에 기록합니다(바뀐 파일만 씁니다)")
            Button("취소") { model.cancelEditing() }
                .buttonStyle(.bordered)
                .help("아무것도 저장하지 않고 닫습니다")
        }
    }
}

/// 배치 미리보기. **저장 전 배치로 실제 바와 같은 계산**(`DockDisplayBuilder`)을 써서
/// 순서·영역 폭·카드·밀린 항목 수를 그대로 보여준다.
struct DockLayoutPreview: View {
    @ObservedObject var model: DockModel

    private let previewWidth: CGFloat = 620

    private var display: DockDisplay {
        DockDisplayBuilder.make(
            resolution: model.resolution,
            layout: model.effectiveLayout,
            screenWidth: ScreenGeometry.fallbackFrame.width,
            showsFakeBadge: model.isFake
        )
    }

    private var scale: CGFloat {
        let width = max(display.barWidth, 1)
        return previewWidth / width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(renderedComponents, id: \.self) { component in
                    if component != renderedComponents.first { separator }
                    componentBlock(component)
                }
                Spacer(minLength: 0)
                Text("⋯")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DockBarLayout.widgetPadding * scale)
            .frame(width: previewWidth, height: max(34, DockBarLayout.widgetBarHeight * scale), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var renderedComponents: [DockComponent] {
        model.effectiveLayout.order.filter { component in
            switch component {
            case .common: return !model.resolution.commonItems.isEmpty
            case .cards: return !model.effectiveLayout.cards.isEmpty
            case .project: return true
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: max(18, 52 * scale))
    }

    @ViewBuilder
    private func componentBlock(_ component: DockComponent) -> some View {
        switch component {
        case .common:
            HStack(spacing: DockBarLayout.tileGap * scale) {
                ForEach(0..<min(model.display.common.count, 8), id: \.self) { index in
                    block(
                        width: DockBarLayout.appTileSize * scale,
                        height: DockBarLayout.appTileSize * scale,
                        radius: 6,
                        label: shortLabel(model.display.common[index].item.name)
                    )
                }
                if model.display.commonHidden > 0 {
                    block(
                        width: DockBarLayout.appTileSize * scale,
                        height: DockBarLayout.appTileSize * scale,
                        radius: 6,
                        label: "+\(model.display.commonHidden)"
                    )
                }
            }
        case .cards:
            HStack(spacing: DockBarLayout.cardGap * scale) {
                ForEach(model.effectiveLayout.cards) { card in
                    block(
                        width: (card.kind == .clock ? DockBarLayout.clockCardWidth : DockBarLayout.timerCardWidth) * scale,
                        height: DockBarLayout.cardHeight * scale,
                        radius: 6,
                        label: card.kind == .clock ? "시계" : "타이머"
                    )
                }
            }
        case .project:
            HStack(spacing: DockBarLayout.tileGap * scale) {
                if model.resolution.hasProject {
                    ForEach(0..<min(model.display.project.count, 5), id: \.self) { index in
                        block(
                            width: DockBarLayout.projectTileSize * scale,
                            height: DockBarLayout.projectTileSize * scale,
                            radius: 5,
                            label: shortLabel(model.display.project[index].item.name)
                        )
                    }
                    if model.display.projectHidden > 0 {
                        block(
                            width: DockBarLayout.projectTileSize * scale,
                            height: DockBarLayout.projectTileSize * scale,
                            radius: 5,
                            label: "⋯"
                        )
                    }
                } else {
                    Text("미등록 경로").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8 * scale)
            .frame(width: CGFloat(display.projectAreaWidth) * scale, height: DockBarLayout.cardHeight * scale, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        model.resolution.hasProject ? Color.primary.opacity(0.25) : Color.orange.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
        }
    }

    private func block(width: CGFloat, height: CGFloat, radius: CGFloat, label: String) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.10))
            .frame(width: max(8, width), height: max(8, height))
            .overlay(
                Text(label).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            )
    }

    private func shortLabel(_ name: String) -> String {
        name.count <= 4 ? name : String(name.prefix(4))
    }

    private var caption: String {
        "바 \(Int(display.barWidth))pt · 프로젝트 영역 \(Int(display.projectAreaWidth))pt · "
            + "보이는 항목 \(display.visibleItemCount)개 · 숨김 \(display.hiddenItemCount)개"
            + (display.isSpaceShort ? " · 공간 부족(영역을 줄였습니다)" : "")
    }
}

/// 목록 안 드래그 순서 변경. 드래그 중인 id는 모델이 들고 있다.
struct ItemDropDelegate: DropDelegate {
    let model: DockModel
    let targetIndex: Int

    func performDrop(info: DropInfo) -> Bool {
        guard let dragging = model.editorDragging else {
            model.editorEndDrag()
            return false
        }
        model.editorDrop(dragging, toIndex: targetIndex)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
