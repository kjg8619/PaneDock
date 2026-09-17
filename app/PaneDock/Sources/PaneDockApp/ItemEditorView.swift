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
            footer
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560, alignment: .topLeading)
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
            Button("저장") { model.saveDraft() }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft == nil)
                .help("편집한 구성을 디스크에 기록합니다")
            Button("취소") { model.cancelEditing() }
                .buttonStyle(.bordered)
                .help("아무것도 저장하지 않고 닫습니다")
        }
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
