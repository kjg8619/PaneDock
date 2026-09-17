import AppKit
import Combine
import FocusProbeCore
import Foundation
import UniformTypeIdentifiers

/// 화면 상태를 소유한다. 추적은 백그라운드 큐에서 돌리고, 결과만 메인으로 가져온다.
///
/// 지키는 것:
/// - 조회가 느리거나 실패해도 UI를 멈추지 않는다(메인 스레드에서 조회하지 않는다).
/// - 클릭 시점의 값으로 실행 계획을 만든다. 클릭 도중 도착한 갱신이 실행 대상을 바꾸지 못한다.
/// - 잠금 중에는 새 후보로 바뀌지 않는다. 잠금 해제 시 현재 포커스를 다시 확인한다.
/// - PaneDock은 스스로를 활성화하지 않는다(`activate` 호출 없음). 창은 non-activating panel이다.
@MainActor
final class DockModel: ObservableObject {
    /// 키보드로 이동할 수 있는 항목. 화면에 보이는 순서와 같다.
    enum FocusItem: Equatable {
        case item(Int)
        case openFolder
        case copyPath
        case lock
        /// 상세 보기 열기.
        case more
        /// 상세 보기 닫기.
        case detailsClose
        case hide
        case quit

        var label: String {
            switch self {
            case .item(let index): return "item:\(index)"
            case .openFolder: return "openFolder"
            case .copyPath: return "copyPath"
            case .lock: return "lock"
            case .more: return "more"
            case .detailsClose: return "detailsClose"
            case .hide: return "hide"
            case .quit: return "quit"
            }
        }
    }

    /// 실행이 어디서 들어왔는지. 마우스와 키보드가 **같은 검증 경로**를 쓰는지 로그로 확인한다.
    enum ActionSource: String {
        case mouse
        case keyboard
        case menu
    }

    @Published private(set) var state: DockState
    @Published private(set) var actionMessage: String?
    @Published private(set) var isFake: Bool
    @Published private(set) var refreshCount = 0
    /// 키보드 포커스가 놓인 항목. 호출했을 때만 값이 있다.
    @Published private(set) var focusedItem: FocusItem?
    /// 마우스가 올라간 항목. 키보드 선택과 **다르게** 표시하기 위해 따로 둔다.
    ///
    /// SwiftUI `@State`는 이 빌드 환경(Command Line Tools만, 매크로 플러그인 없음)에서 쓸 수 없어
    /// `focusedItem`과 같은 방식으로 모델이 들고 있는다.
    @Published private(set) var hoveredItem: FocusItem?
    /// 현재 표시 대상에 해당하는 프로젝트. 없으면 기본 Dock으로 동작한다.
    /// 현재 표시 묶음(공통 항목 + 프로젝트 항목). 프로젝트가 없어도 만들어진다.
    @Published private(set) var resolution = ProjectResolution(
        projectID: "", projectName: "", projectRoot: "", matchedCWD: "",
        commonItems: [], projectItems: [], diagnostics: []
    )
    /// 설정 파일 관련 안내(손상·미래 버전 등). 없으면 nil.
    @Published private(set) var settingsNotice: String?
    /// 프로젝트 설정 상태 안내(다시 읽기 결과·경고). 없으면 nil.
    @Published private(set) var catalogNotice: String?

    /// 창 숨기기 요청. AppDelegate가 처리한다.
    var onHide: (() -> Void)?

    /// 편집창 열기 요청. AppDelegate가 창을 만든다.
    var onOpenEditor: (() -> Void)?
    /// 편집창 닫기 요청(저장 성공·취소). AppDelegate가 창을 닫는다.
    var onCloseEditor: (() -> Void)?
    /// 초안 저장 요청. AppDelegate가 실제 파일에 쓰고 (안내문, 성공 여부)를 돌려준다.
    var onSaveDraft: ((ProjectCatalog) -> (message: String, succeeded: Bool))?

    /// 편집 중인 초안. nil이면 편집 중이 아니다.
    ///
    /// **저장/취소 전에는 실제 구성에 반영되지 않는다.** 편집 범위는 열 때 정해지고,
    /// 터미널 포커스가 바뀌어도 자동으로 바뀌지 않는다.
    @Published private(set) var draft: ProjectCatalogDraft?
    /// 저장된 Dock 외형.
    @Published private(set) var appearance: DockAppearance = .default
    /// 편집창에서 **미리 보는** 외형. 저장 전에는 디스크에 쓰지 않는다.
    @Published private(set) var previewAppearance: DockAppearance?

    /// 화면이 실제로 쓸 외형(미리보기 우선).
    var effectiveAppearance: DockAppearance { previewAppearance ?? appearance }

    /// 저장된 외형을 반영한다(시작 시·저장 후).
    func applyAppearance(_ appearance: DockAppearance) {
        self.appearance = appearance
        previewAppearance = nil
        onLayoutChange?()
    }

    /// 편집창에서 외형을 **미리** 바꾼다. 디스크에는 쓰지 않는다.
    func previewAppearanceChange(_ appearance: DockAppearance) {
        previewAppearance = appearance
        stateLog?.appendEvent("appearance=preview size=\(appearance.size.rawValue) label=\(appearance.labelMode.rawValue) color=\(appearance.colorMode.rawValue) display=\(appearance.displayMode.rawValue)")
        onLayoutChange?()
    }

    /// 외형 저장 요청. AppDelegate가 설정 파일에 쓰고 성공 여부를 돌려준다.
    var onSaveAppearance: ((DockAppearance) -> (message: String, succeeded: Bool))?

    /// 미리보기를 버리고 저장된 외형으로 돌아간다(취소·창 닫기).
    func discardAppearancePreview() {
        guard previewAppearance != nil else { return }
        previewAppearance = nil
        stateLog?.appendEvent("appearance=preview result=discarded")
        onLayoutChange?()
    }

    /// 미리보기 외형을 저장한다. **성공 여부를 돌려준다.**
    @discardableResult
    func saveAppearancePreview() -> Bool {
        guard let previewAppearance else { return true }
        let result = onSaveAppearance?(previewAppearance) ?? (message: "저장할 수 없습니다: 설정을 쓸 수 없습니다", succeeded: false)
        editorNotice = result.message
        stateLog?.appendEvent("appearance=save result=\(result.succeeded ? "ok" : "failed")")
        if result.succeeded { self.previewAppearance = nil }
        return result.succeeded
    }

    /// 편집창 안내(저장 결과·충돌·검증 실패). 없으면 nil.
    @Published private(set) var editorNotice: String?

    /// 편집창에서 고른 항목.
    @Published private(set) var editorSelection: String?
    /// 편집창의 입력 폼. `editingID`가 있으면 그 항목을 고치는 중이다.
    struct ItemForm: Equatable {
        var kind: DockItemKind = .link
        var name: String = ""
        var target: String = ""
        var editingID: String?
        var isPresented = false
    }
    @Published private(set) var editorForm = ItemForm()
    /// 드래그로 옮기는 중인 항목 id. 드래그 중에는 실행하지 않는다.
    @Published private(set) var editorDragging: String?

    /// 상세 보기 표시 여부. 창 크기는 AppDelegate가 이 값에 맞춘다.
    @Published private(set) var isDetailsVisible = false
    /// **자동 접기** 상태(작은 호출 손잡이만 남긴 상태).
    /// 표시 방식일 뿐이며 **추적·잠금·표시 대상과는 분리**돼 있다.
    @Published private(set) var isCollapsed = false
    /// 창 크기 재계산 요청. AppDelegate가 처리한다.
    var onLayoutChange: (() -> Void)?

    private let probe: GhosttyProbe
    private let queue = DispatchQueue(label: "pane-dock.probe")
    private let validator = FileSystemPathValidator()

    private var snapshot: DiagnosticSnapshot?
    /// 사용자가 등록한 프로젝트 카탈로그(정적 설정). 실시간 CWD와는 별개다.
    private var catalog = ProjectCatalog()
    private var catalogDiagnostics: [String] = []
    /// 화면에 마지막으로 반영된 대상. 버튼은 **이 값**으로만 실행 계획을 만든다.
    /// 조회 결과와 화면 반영이 어긋나는 순간이 생겨도 실행 대상이 흔들리지 않게 한다.
    private var actionInfo: CurrentWorkInfo?
    private var failureText: String?
    private var lock = DockLock()
    private var isRefreshing = false
    private var timer: Timer?
    private let stateLog: StateLog?

    /// 사용자가 명시적으로 Dock을 호출한 상태인지.
    private var isDockInvoked = false
    /// 마지막 조회 시점에 **현재 대상이 포커스 확인을 받은 적 있는지**.
    /// 판정 불가일 때 "마지막으로 확인한 대상"이라고 말해도 되는지 판단하는 데 쓴다.
    private var confirmedTarget = true
    /// 마지막으로 창 크기를 맞췄을 때의 링크 수(불필요한 리사이즈를 피한다).
    private var lastLayoutLinkCount = 0
    /// 호출 직전에 마지막으로 확인한 "바깥 앱 최전면" 값.
    /// 호출 중에는 이 값으로 고정해, **우리 자신의 활성화를 작업 위치 이동으로 해석하지 않는다.**
    private var frozenHostFrontmost: Bool?

    init(adapter: TerminalHostAdapter, isFake: Bool, stateLogPath: String? = nil) {
        self.probe = GhosttyProbe(adapter: adapter)
        self.isFake = isFake
        self.stateLog = stateLogPath.map(StateLog.init(path:))
        self.state = DockStateBuilder.make(
            current: nil,
            previous: nil,
            connection: .unavailable,
            failure: nil,
            lock: DockLock()
        )
    }

    // MARK: - 조회

    func start(intervalMilliseconds: Int) {
        refreshNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMilliseconds) / 1000.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    /// 한 번 조회한다. 이미 조회 중이면 건너뛴다(중첩 방지).
    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true

        let probe = self.probe
        queue.async { [weak self] in
            _ = probe.refresh()
            let snapshot = probe.diagnostic()
            let failure = probe.store.lastFailure
            let confirmed = probe.store.hasConfirmedCurrentTarget
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.failureText = failure
                self.confirmedTarget = confirmed
                self.isRefreshing = false
                self.refreshCount += 1
                self.rebuildState()
            }
        }
    }

    private func rebuildState() {
        let effectiveCurrent = snapshot?.current
        state = DockStateBuilder.make(
            current: effectiveCurrent,
            previous: snapshot?.previous,
            connection: effectiveCurrent?.connectionStatus ?? .unavailable,
            failure: failureText,
            lock: lock,
            // 호출 중에는 최전면 판정만 호출 직전 값으로 고정한다.
            // 연결 오류·경로 무효화는 그대로 드러난다.
            hostFrontmostOverride: isDockInvoked ? frozenHostFrontmost : nil,
            hasConfirmedTarget: confirmedTarget
        )
        // 화면에 반영한 것과 **같은 값**을 실행 대상으로 고정한다.
        actionInfo = lock.info ?? effectiveCurrent
        // 프로젝트 판정도 **화면에 반영한 CWD**로만 만든다.
        // 표시된 링크와 실행 대상이 어긋나지 않게 하기 위해서다.
        // 프로젝트가 없어도 **공통 항목은 담긴다**.
        resolution = ProjectResolver.resolve(
            cwd: actionInfo?.reportedCWD ?? "",
            catalog: catalog,
            catalogDiagnostics: catalogDiagnostics
        )
        // 프로젝트가 바뀌어 링크 수가 달라지면 바 너비도 달라진다.
        let linkCount = resolution.allItems.count
        if linkCount != lastLayoutLinkCount {
            lastLayoutLinkCount = linkCount
            onLayoutChange?()
        }
        stateLog?.append(
            refresh: refreshCount,
            display: state.display.rawValue,
            // 어느 터미널을 따라가고 있는지, 그 경로가 어디서 왔는지 남긴다(호스트 전환 검증용).
            host: actionInfo?.identity.hostAppID ?? state.hostAppID ?? "-",
            source: actionInfo?.cwdSource?.rawValue ?? "-",
            folderName: state.folderName,
            fullPath: state.fullPath ?? "-",
            paneID: state.paneID ?? "-",
            locked: state.isLocked,
            project: resolution.hasProject ? "\(resolution.projectID)(\(resolution.allItems.count))" : "-"
        )
    }

    /// 지금 화면에 보이는 대상. 잠금이 걸려 있으면 잠긴 대상이다.
    /// 버튼은 이 값으로만 계획을 만든다(클릭 도중 도착한 갱신이 실행 대상을 바꾸지 못한다).
    private func displayedInfo() -> CurrentWorkInfo? {
        actionInfo
    }

    // MARK: - 잠금

    func toggleLock() {
        if lock.isLocked {
            lock.unlock()
            actionMessage = "잠금을 해제했습니다. 현재 포커스를 다시 확인합니다."
            rebuildState()
            // 잠금 해제 직후 현재 포커스를 다시 확인한다.
            refreshNow()
            return
        }

        guard let info = snapshot?.current, info.pathStatus == .valid else {
            actionMessage = "고정할 대상을 확인하지 못했습니다."
            return
        }
        lock.lock(info)
        actionMessage = "표시 대상을 고정했습니다: \(info.reportedCWD ?? "-")"
        rebuildState()
    }

    // MARK: - 실행 (마우스와 키보드가 같은 경로를 쓴다)

    func hideWindow() {
        onHide?()
    }

    // MARK: - 접기/펼치기 (표시만 바꾼다)

    /// 키보드 호출 세션이 진행 중인가(자동 접기 판단에 쓴다).
    var isKeyboardSessionActive: Bool { isDockInvoked }

    /// 접힘/펼침을 바꾼다. **추적·잠금·표시 대상은 건드리지 않는다.**
    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        stateLog?.appendEvent("collapse state=\(collapsed ? "collapsed" : "expanded")")
        onLayoutChange?()
    }

    /// 호출 손잡이에서 펼친다. **호출(키보드) 세션은 시작하지 않는다** —
    /// hover만으로 고정 세션이 열리면 안 되기 때문이다.
    func expandFromHandle() {
        setCollapsed(false)
    }

    // MARK: - 호출 상태 (키보드 접근)

    /// 호출/닫힘을 알린다. 호출 중에는 화면에 포커스를 주고, 닫으면 현재 상태를 다시 확인한다.
    func setDockInvoked(_ invoked: Bool) {
        guard isDockInvoked != invoked else { return }
        isDockInvoked = invoked
        if invoked {
            // 우리 자신의 활성화를 "다른 앱으로 이동"으로 해석하지 않도록 직전 값을 붙잡아 둔다.
            frozenHostFrontmost = snapshot?.current.hostFrontmost
            focusedItem = firstAvailableItem()
            stateLog?.appendEvent(
                "invoke frozenFrontmost=\(frozenHostFrontmost.map(String.init) ?? "unknown") focus=\(focusedItem?.label ?? "-") target=\(snapshot?.current.reportedCWD ?? "-")"
            )
        } else {
            frozenHostFrontmost = nil
            focusedItem = nil
            stateLog?.appendEvent("close target=\(snapshot?.current.reportedCWD ?? "-")")
            // 닫을 때 현재 상태를 다시 확인한다. 다른 앱으로 이동한 의도를 덮어쓰지 않는다
            // (Ghostty를 강제로 활성화하지 않는다).
            refreshNow()
        }
        rebuildState()
    }

    /// 설정 안내 문구를 넣는다(설정 파일 손상·미래 버전 등).
    func setSettingsNotice(_ notice: String?) {
        settingsNotice = notice
    }

    /// 진단용 사건 기록. 창을 보지 않고도 동작을 확인할 수 있게 한다.
    func appendEvent(_ text: String) {
        stateLog?.appendEvent(text)
    }

    /// 프로젝트 카탈로그를 반영한다. 실시간 CWD와는 별개인 정적 설정이다.
    ///
    /// 링크 목록이 달라졌으면 **진행 중인 링크 선택을 취소**한다.
    /// 이전 인덱스를 새 목록에 그대로 적용하지 않는다. 재로딩은 아무것도 실행하지 않는다.
    func updateCatalog(_ catalog: ProjectCatalog, diagnostics: [String], note: String? = nil) {
        let previousResolution = resolution
        self.catalog = catalog
        self.catalogDiagnostics = diagnostics
        catalogNotice = note
        rebuildState()

        if case .item = focusedItem, !ProjectSelection.selectionSurvives(reloadFrom: previousResolution, to: resolution) {
            focusedItem = nil
            stateLog?.appendEvent("selection=cancelled (catalog changed)")
        }
        stateLog?.appendEvent(
            "catalog projects=\(catalog.projects.count) diagnostics=\(diagnostics.count) notice=\(note?.replacingOccurrences(of: "\n", with: " / ") ?? "-")"
        )
    }

    /// 지금 화면에서 이동할 수 있는 항목들. 링크가 먼저, 고정 버튼이 뒤에 온다.
    ///
    /// 상세 보기가 열려 있으면 **모든 링크**가 이동 대상이다(인라인에서 밀린 항목 포함).
    /// 숨기기·종료는 상세 보기 안에 있으므로 열렸을 때만 순회한다.
    var focusItems: [FocusItem] {
        var items: [FocusItem] = []
        let all = resolution.allItems
        let count = isDetailsVisible ? all.count : visibleItemCount
        for index in 0..<min(count, all.count) {
            items.append(.item(index))
        }
        items.append(contentsOf: [.openFolder, .copyPath, .lock])
        items.append(isDetailsVisible ? .detailsClose : .more)
        if isDetailsVisible {
            items.append(contentsOf: [.hide, .quit])
        }
        return items
    }

    /// 바에 인라인으로 그릴 항목 수. 화면 너비와 항목 수로 정해진다.
    var visibleItemCount: Int {
        DockBarLayout.linkBudget(
            total: resolution.allItems.count,
            availableWidth: ScreenGeometry.fallbackFrame.width
        ).visible
    }

    /// 바에 인라인으로 그릴 항목. `id`를 명시해 목록 갱신이 안정적이게 한다.
    struct InlineItem: Identifiable, Equatable {
        var id: String
        var index: Int
        var item: DockItemTarget
    }

    /// 인라인으로 보여줄 항목 목록(공통 → 프로젝트 순서).
    func items(forInline limit: Int) -> [InlineItem] {
        resolution.allItems.prefix(max(0, limit)).enumerated().map {
            InlineItem(id: $0.element.itemID, index: $0.offset, item: $0.element)
        }
    }

    func showDetails() {
        guard !isDetailsVisible else { return }
        isDetailsVisible = true
        stateLog?.appendEvent("details=open")
        onLayoutChange?()
    }

    func hideDetails() {
        guard isDetailsVisible else { return }
        isDetailsVisible = false
        stateLog?.appendEvent("details=close")
        onLayoutChange?()
    }

    func toggleDetails() {
        isDetailsVisible ? hideDetails() : showDetails()
    }

    // MARK: - Dock 편집 (초안 → 저장/취소)

    /// 편집을 시작한다. 범위를 지정하지 않으면 **지금 표시 중인 대상**을 고른다.
    /// 이후 포커스가 바뀌어도 이 범위는 바뀌지 않는다.
    func beginEditing(scope: ItemScope? = nil) {
        // 편집을 시작할 때 **상세 보기는 접는다**(편집창과 겹쳐 화면이 복잡해지지 않게).
        hideDetails()
        // 편집창은 **지금 저장된 외형**에서 시작한다(미리보기는 열 때 초기화).
        previewAppearance = nil
        let chosen = scope ?? (resolution.hasProject ? ItemScope.project(id: resolution.projectID) : .common)
        // 없는 프로젝트를 가리키면 공통으로 떨어진다.
        let safe = ProjectCatalogDraft(catalog: catalog, scope: chosen).isScopeAvailable(chosen) ? chosen : .common
        draft = ProjectCatalogDraft(catalog: catalog, scope: safe)
        editorNotice = nil
        stateLog?.appendEvent("editor=open scope=\(safe.scopeID)")
    }

    /// 편집을 취소한다. **아무것도 저장하지 않는다.**
    func cancelEditing() {
        draft = nil
        editorNotice = nil
        // 미리보기 외형도 버린다(저장한 외형으로 돌아간다).
        discardAppearancePreview()
        stateLog?.appendEvent("editor=close result=cancelled")
        onCloseEditor?()
    }

    /// 편집 범위를 사용자가 직접 바꾼다(자동 변경 경로는 없다).
    func selectEditingScope(_ scope: ItemScope) {
        draft?.selectScope(scope)
        editorSelection = nil
        editorForm = ItemForm()
    }

    // MARK: - 편집창의 목록·폼 (매크로 `@State`를 쓸 수 없어 모델이 들고 있는다)

    func editorSelect(_ itemID: String?) {
        editorSelection = itemID
    }

    func editorBeginAdd(kind: DockItemKind = .link) {
        editorForm = ItemForm(kind: kind, name: "", target: "", editingID: nil, isPresented: true)
    }

    func editorBeginEdit(_ itemID: String) {
        guard let item = draft?.items.first(where: { $0.id == itemID }) else { return }
        editorForm = ItemForm(kind: item.kind, name: item.name, target: item.target, editingID: item.id, isPresented: true)
    }

    func editorCancelForm() {
        editorForm = ItemForm()
    }

    func editorUpdateForm(kind: DockItemKind? = nil, name: String? = nil, target: String? = nil) {
        if let kind { editorForm.kind = kind }
        if let name { editorForm.name = name }
        if let target { editorForm.target = target }
    }

    /// 폼 내용을 초안에 반영한다(추가 또는 수정). 문제가 있으면 안내만 하고 반영하지 않는다.
    func editorCommitForm() {
        guard var draft, editorForm.isPresented else { return }
        let candidate = DockItem(
            id: editorForm.editingID ?? ProjectCatalogDraft.makeItemID(existing: Set(allItemIDs())),
            kind: editorForm.kind,
            name: editorForm.name.trimmingCharacters(in: .whitespacesAndNewlines),
            target: editorForm.target.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let problem = DockItemValidator.problem(with: candidate) {
            editorNotice = "항목을 저장할 수 없습니다: \(problem)"
            return
        }
        if editorForm.editingID != nil {
            draft.update(candidate)
        } else {
            draft.add(candidate)
        }
        self.draft = draft
        editorSelection = candidate.id
        editorForm = ItemForm()
        editorNotice = nil
    }

    /// 항목을 초안에서 뺀다. **앱·폴더·원본 파일은 지우지 않는다.**
    func editorRemove(_ itemID: String) {
        guard var draft else { return }
        draft.remove(itemID: itemID)
        self.draft = draft
        if editorSelection == itemID { editorSelection = nil }
        if editorForm.editingID == itemID { editorForm = ItemForm() }
    }

    /// 키보드로 한 칸 이동(드래그를 쓰지 않는 사용자용).
    func editorMove(_ itemID: String, by offset: Int) {
        guard var draft else { return }
        let before = draft.items.map(\.id)
        draft.move(itemID: itemID, by: offset)
        self.draft = draft
        let after = draft.items.map(\.id)
        stateLog?.appendEvent(
            "editor=move scope=\(draft.scope.scopeID) item=\(itemID) by=\(offset) before=\(before.joined(separator: ",")) after=\(after.joined(separator: ","))"
        )
    }

    func editorBeginDrag(_ itemID: String) {
        editorDragging = itemID
        // 로그에는 범위·항목 ID만 남긴다(이름·URL은 남기지 않는다).
        stateLog?.appendEvent("editor=drag scope=\(draft?.scope.scopeID ?? "-") item=\(itemID)")
    }

    func editorDrop(_ itemID: String, toIndex index: Int) {
        defer { editorDragging = nil }
        guard var draft, editorDragging != nil || editorSelection != nil else { return }
        let before = draft.items.map(\.id)
        draft.move(itemID: itemID, toIndex: index)
        self.draft = draft
        let after = draft.items.map(\.id)
        stateLog?.appendEvent(
            "editor=drop scope=\(draft.scope.scopeID) item=\(itemID) toIndex=\(index) before=\(before.joined(separator: ",")) after=\(after.joined(separator: ","))"
        )
    }

    func editorEndDrag() {
        editorDragging = nil
    }

    /// 새 프로젝트 등록(이름 + 기준 폴더).
    func editorAddProject(name: String, root: String) {
        guard var draft else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, root.hasPrefix("/") else {
            editorNotice = "프로젝트를 추가하려면 이름과 절대 경로 기준 폴더가 필요합니다."
            return
        }
        let id = draft.addProject(name: trimmed, root: root)
        self.draft = draft
        draft.selectScope(.project(id: id))
        self.draft = draft
        editorNotice = nil
    }

    /// 초안 안의 모든 항목 id(중복 없는 새 id를 만들기 위해).
    func allItemIDs() -> [String] {
        guard let draft else { return [] }
        return draft.catalog.common.map(\.id) + draft.catalog.projects.flatMap { $0.items.map(\.id) }
    }

    // MARK: - 새 프로젝트 입력

    @Published private(set) var newProjectName = ""
    @Published private(set) var newProjectRoot = ""

    func editorUpdateNewProject(name: String? = nil, root: String? = nil) {
        if let name { newProjectName = name }
        if let root { newProjectRoot = root }
    }

    /// 기준 폴더를 **사용자가 직접** 고른다(파일 선택 대화상자).
    func pickNewProjectRoot() {
        guard let picked = runOpenPanel(
            message: "프로젝트 기준 폴더를 고르세요",
            directories: true,
            files: false
        ) else { return }
        newProjectRoot = picked.path
    }

    /// 폼의 대상(앱·폴더)을 사용자가 고른다.
    func pickTargetForForm() {
        switch editorForm.kind {
        case .app:
            guard let picked = runOpenPanel(
                message: "앱(.app)을 고르세요",
                directories: true,
                files: true,
                directoryType: .applicationBundle
            ) else { return }
            editorUpdateForm(target: picked.path)
            if editorForm.name.trimmingCharacters(in: .whitespaces).isEmpty {
                editorUpdateForm(name: picked.deletingPathExtension().lastPathComponent)
            }
        case .folder:
            guard let picked = runOpenPanel(
                message: "고정 폴더를 고르세요",
                directories: true,
                files: false
            ) else { return }
            editorUpdateForm(target: picked.path)
            if editorForm.name.trimmingCharacters(in: .whitespaces).isEmpty {
                editorUpdateForm(name: picked.lastPathComponent)
            }
        case .link:
            return
        }
    }

    private func runOpenPanel(
        message: String,
        directories: Bool,
        files: Bool,
        directoryType: UTType? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = directories
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "선택"
        if let directoryType {
            panel.allowedContentTypes = [directoryType]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 새 프로젝트를 초안에 추가하고 그 범위로 이동한다.
    func commitNewProject() {
        editorAddProject(name: newProjectName, root: newProjectRoot)
        if editorNotice == nil {
            newProjectName = ""
            newProjectRoot = ""
        }
    }

    /// 편집창의 **저장**: 모양 미리보기와 항목 초안을 함께 저장한다.
    func saveAll() {
        var saved: [String] = []
        var failed: [String] = []
        var unchanged: [String] = []
        // **바뀐 것만 쓴다.** 값이 같으면 파일을 건드리지 않는다(백업도 만들지 않는다).
        if let preview = previewAppearance {
            if preview == appearance {
                unchanged.append("모양")
                discardAppearancePreview()
            } else if saveAppearancePreview() {
                saved.append("모양")
            } else {
                failed.append("모양")
            }
        }
        // 항목은 **창을 닫지 않고** 저장한다(모양이 실패했는데 창이 닫히면 실패가 가려진다).
        if let current = draft {
            if current.catalog == catalog {
                unchanged.append("항목")
                draft = nil
            } else if saveDraft(closeOnSuccess: false) {
                saved.append("항목")
            } else {
                failed.append("항목")
            }
        }
        guard failed.isEmpty else {
            // 하나만 저장된 상태를 "전체 성공"으로 보여주지 않는다.
            editorNotice = "일부만 저장했습니다 — 저장됨: \(saved.isEmpty ? "없음" : saved.joined(separator: ", ")) / 실패: \(failed.joined(separator: ", "))"
            stateLog?.appendEvent("editor=save result=partial saved=\(saved.count) failed=\(failed.count) unchanged=\(unchanged.count)")
            return
        }
        stateLog?.appendEvent("editor=save result=ok saved=\(saved.count) unchanged=\(unchanged.count)")
        // 저장할 것이 없었으면 그렇게 말하고, 있으면 이제 닫는다.
        if saved.isEmpty {
            editorNotice = unchanged.isEmpty ? "변경된 내용이 없습니다." : "변경된 내용이 없습니다(같은 값이라 파일을 쓰지 않았습니다)."
        }
        draft = nil
        onCloseEditor?()
    }

    /// 초안을 저장한다. 파일 쓰기는 AppDelegate가 하고, 여기서는 결과만 받는다.
    ///
    /// 성공하면 AppDelegate가 **기존 재로딩 경로**로 즉시 반영한다(선택 취소 포함).
    @discardableResult
    func saveDraft(closeOnSuccess: Bool = true) -> Bool {
        guard let draft else { return false }
        let problems = draft.fatalProblems()
        guard problems.isEmpty else {
            editorNotice = "저장할 수 없습니다:\n" + problems.prefix(3).joined(separator: "\n")
            stateLog?.appendEvent("editor=save result=refused problems=\(problems.count)")
            return false
        }
        let result = onSaveDraft?(draft.catalog) ?? (message: "저장할 수 없습니다: 설정 파일을 사용할 수 없습니다", succeeded: false)
        editorNotice = result.message
        stateLog?.appendEvent("editor=save result=\(result.succeeded ? "ok" : "failed")")
        // 저장에 성공하면 편집을 끝낸다(구성은 재로딩으로 이미 반영됐다). 창은 요청에 따라 닫는다.
        if result.succeeded {
            self.draft = nil
            if closeOnSuccess { onCloseEditor?() }
        }
        return result.succeeded
    }

    /// 마우스 hover 표시를 갱신한다. 벗어나면 그 항목일 때만 지운다.
    func setHover(_ item: FocusItem?) {
        if let item {
            hoveredItem = item
        } else if hoveredItem != nil {
            hoveredItem = nil
        }
    }

    func moveFocus(forward: Bool) {
        let items = focusItems
        guard !items.isEmpty else { return }
        guard let current = focusedItem, let index = items.firstIndex(of: current) else {
            focusedItem = forward ? items.first : items.last
            stateLog?.appendEvent("focus=\(focusedItem?.label ?? "-")")
            return
        }
        let offset = forward ? 1 : items.count - 1
        focusedItem = items[(index + offset) % items.count]
        stateLog?.appendEvent("focus=\(focusedItem?.label ?? "-")")
    }

    func activateFocusedItem() {
        stateLog?.appendEvent("activate control=\(focusedItem?.label ?? "-") source=keyboard")
        guard let focusedItem else {
            // 재로딩 등으로 선택이 취소된 상태. 아무것도 실행하지 않는다.
            actionMessage = "선택된 항목이 없습니다. Tab으로 항목을 고르세요."
            stateLog?.appendEvent("activate control=nil source=keyboard result=ignored")
            return
        }
        switch focusedItem {
        case .item(let index): performItem(at: index, source: .keyboard)
        case .openFolder: perform(.openFolder, source: .keyboard)
        case .copyPath: perform(.copyPath, source: .keyboard)
        case .lock: toggleLock()
        case .more: showDetails()
        case .detailsClose: hideDetails()
        case .hide: hideWindow()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    private func firstAvailableItem() -> FocusItem {
        if !resolution.allItems.isEmpty { return .item(0) }
        if state.canOpenFolder { return .openFolder }
        if state.canCopyPath { return .copyPath }
        return .lock
    }

    // MARK: - 항목 실행 (앱·폴더·링크)

    /// 항목을 실행한다. 마우스와 키보드가 **같은 검증 경로**(`DockItemActionPlanner`)를 쓴다.
    ///
    /// **드래그·편집 중에는 호출되지 않는다** — 실행은 클릭/Enter로만 들어온다.
    func performItem(at index: Int, source: ActionSource = .mouse) {
        let all = resolution.allItems
        guard all.indices.contains(index) else {
            actionMessage = "선택한 항목을 현재 표시에서 찾을 수 없습니다"
            stateLog?.appendEvent("item=\(index) source=\(source.rawValue) result=missing")
            return
        }
        let target = all[index]
        switch DockItemActionPlanner.plan(target: target, in: resolution, state: state, validator: validator) {
        case .openApplication(let url):
            logItem(target, source: source, result: "allowed", detail: "app")
            let opened = NSWorkspace.shared.open(url)
            actionMessage = opened ? "앱을 열었습니다: \(target.name)" : "앱을 열지 못했습니다: \(target.target)"
        case .openFolder(let url):
            logItem(target, source: source, result: "allowed", detail: "folder")
            let opened = NSWorkspace.shared.open(url)
            actionMessage = opened ? "폴더를 열었습니다: \(target.name)" : "폴더를 열지 못했습니다: \(target.target)"
        case .openURL(let url):
            // 로그에는 쿼리·프래그먼트를 뺀 형태만 남긴다(토큰 노출 방지).
            logItem(target, source: source, result: "allowed", detail: ProjectLinkPrivacy.redactedForLog(target.target))
            let opened = NSWorkspace.shared.open(url)
            actionMessage = opened ? "링크를 열었습니다: \(target.name)" : "링크를 열지 못했습니다: \(target.target)"
        case .reject(let reason):
            logItem(target, source: source, result: "rejected", detail: "reason=\(reason)")
            actionMessage = reason
        }
    }

    private func logItem(_ target: DockItemTarget, source: ActionSource, result: String, detail: String) {
        let scope = target.isCommon ? "common" : target.scopeID
        stateLog?.appendEvent(
            "item=\(target.itemID) kind=\(target.kind.rawValue) scope=\(scope) source=\(source.rawValue) result=\(result) \(detail)"
        )
    }

    // MARK: - 실행 (마우스와 키보드가 같은 경로를 쓴다)

    /// 실행 계획을 만들기 전에 **표시 상태로 한 번 더 막는다.**
    /// 오류·확인 중에는 마우스든 키보드든 우회할 수 없다.
    func perform(_ action: DockAction, source: ActionSource = .mouse) {
        guard isAllowed(action) else {
            let message = blockedMessage(for: action)
            actionMessage = message
            stateLog?.appendEvent("action=\(action.rawValue) source=\(source.rawValue) result=blocked reason=\(message)")
            return
        }
        // 클릭/키 입력 순간의 값을 고정한다. 이후 도착한 갱신은 이 결정에 영향을 주지 않는다.
        let info = displayedInfo()
        let plan = DockActionPlanner.plan(action, for: info, validator: validator)
        stateLog?.appendEvent(
            "action=\(action.rawValue) source=\(source.rawValue) result=allowed target=\(info?.reportedCWD ?? "-") pane=\(info?.identity.paneID ?? "-")"
        )
        switch plan {
        case .openFolder(let url):
            let opened = NSWorkspace.shared.open(url)
            actionMessage = opened ? "폴더를 열었습니다: \(url.path)" : "폴더를 열지 못했습니다: \(url.path)"
        case .copyPath(let path):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(path, forType: .string)
            actionMessage = "경로를 복사했습니다: \(path)"
        case .reject(let reason):
            actionMessage = reason
            stateLog?.appendEvent("action=\(action.rawValue) source=\(source.rawValue) result=rejected reason=\(reason)")
        }
    }

    private func isAllowed(_ action: DockAction) -> Bool {
        switch action {
        case .openFolder: return state.canOpenFolder
        case .copyPath: return state.canCopyPath
        }
    }

    private func blockedMessage(for action: DockAction) -> String {
        let what = action == .openFolder ? "폴더 열기" : "경로 복사"
        return "\(what)를 할 수 없습니다: \(state.detail ?? "실행할 대상을 확인하는 중입니다")"
    }
}
