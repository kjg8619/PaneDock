import AppKit
import Combine
import FocusProbeCore
import Foundation
import UniformTypeIdentifiers

/// `NSMenu` 항목의 실행 대상을 감싼다(메뉴가 닫힌 뒤에도 살아 있게 메뉴가 붙잡는다).
final class MenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        action()
    }
}

/// 화면 상태를 소유한다. 추적은 백그라운드 큐에서 돌리고, 결과만 메인으로 가져온다.
///
/// 지키는 것:
/// - 조회가 느리거나 실패해도 UI를 멈추지 않는다(메인 스레드에서 조회하지 않는다).
/// - 클릭 시점의 값으로 실행 계획을 만든다. 클릭 도중 도착한 갱신이 실행 대상을 바꾸지 못한다.
/// - 잠금 중에는 새 후보로 바뀌지 않는다. 잠금 해제 시 현재 포커스를 다시 확인한다.
/// - PaneDock은 스스로를 활성화하지 않는다(`activate` 호출 없음). 창은 non-activating panel이다.
@MainActor
final class DockModel: ObservableObject {
    /// 키보드로 이동할 수 있는 곳. **화면에 있는 것만** 들어간다(코어의 `DockFocusPlan`이 정한다).
    /// 항목은 순번이 아니라 **범위 + ID**로 가리킨다 — 목록이 다시 만들어져도 같은 항목만 실행된다.
    typealias FocusItem = DockFocusControl

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
    /// **화면에 실제로 그리는 목록**. 화면·숨김 개수·키보드 이동이 모두 이 하나를 쓴다.
    @Published private(set) var display = DockDisplay.empty
    /// 카드가 쓰는 현재 시각. 1초마다 갱신한다(남은 시간은 이 값과 시작 시각으로 계산한다).
    @Published private(set) var now = Date()
    /// 카드 id별 **실행 상태**(메모리 전용). 프로젝트 전환·접기·배치 변경으로 지우지 않는다.
    @Published private(set) var timerStates: [String: FocusTimerState] = [:]
    /// 지금 실행 중인 앱 번들 경로(앱 타일의 실행 중 표시).
    @Published private(set) var runningAppPaths: Set<String> = []
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
        let labelModeChanged = appearance.labelMode != effectiveAppearance.labelMode
        self.appearance = appearance
        previewAppearance = nil
        if labelModeChanged { rebuildDisplay() }
        onLayoutChange?()
    }

    /// 편집창에서 외형을 **미리** 바꾼다. 디스크에는 쓰지 않는다.
    func previewAppearanceChange(_ appearance: DockAppearance) {
        let labelModeChanged = appearance.labelMode != effectiveAppearance.labelMode
        previewAppearance = appearance
        stateLog?.appendEvent("appearance=preview size=\(appearance.size.rawValue) label=\(appearance.labelMode.rawValue) color=\(appearance.colorMode.rawValue) display=\(appearance.displayMode.rawValue)")
        // 표시 방식(아이콘+이름/아이콘 중심)은 타일 폭·개수를 바꾼다 → 표시 목록을 다시 만든다.
        if labelModeChanged { rebuildDisplay() }
        onLayoutChange?()
    }

    /// 외형 저장 요청. AppDelegate가 설정 파일에 쓰고 성공 여부를 돌려준다.
    var onSaveAppearance: ((DockAppearance) -> (message: String, succeeded: Bool))?

    /// 미리보기를 버리고 저장된 외형으로 돌아간다(취소·창 닫기).
    func discardAppearancePreview() {
        guard previewAppearance != nil else { return }
        let labelModeChanged = previewAppearance?.labelMode != appearance.labelMode
        previewAppearance = nil
        stateLog?.appendEvent("appearance=preview result=discarded")
        if labelModeChanged { rebuildDisplay() }
        onLayoutChange?()
    }

    /// Dock 편집창을 연다(미등록 영역의 `+` 타일도 이 경로를 쓴다).
    func openEditor() {
        onOpenEditor?()
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
    /// 저장된 Dock 배치(순서·프로젝트 영역 너비·카드). **표시 구성만** 정한다 —
    /// 프로젝트 내용·실행 상태와는 별개다.
    private(set) var layout: DockLayout = .default

    /// 편집창에서 **미리 보는** 배치. 저장 전에는 디스크에 쓰지 않는다.
    @Published private(set) var previewLayout: DockLayout?

    /// 이번 실행에서 **한 번이라도 쓴** 카드 id. 삭제한 뒤 다시 추가해도 같은 id를 재사용하지 않는다
    /// (그러지 않으면 새 카드가 지운 카드의 실행 상태를 물려받는다).
    private var usedCardIDs: Set<String> = []

    /// 화면이 실제로 쓸 배치(미리보기 우선).
    var effectiveLayout: DockLayout { previewLayout ?? layout }

    /// 저장하지 않은 배치 변경이 있는가.
    var layoutIsDirty: Bool { previewLayout != nil && previewLayout != layout }

    /// 배치를 반영한다(시작 시·설정 저장 후). 구성만 바뀌고 추적·잠금·대상은 건드리지 않는다.
    func applyLayout(_ layout: DockLayout) {
        self.layout = layout
        previewLayout = nil
        // 이번 실행에서 써 본 카드 id를 기억한다(삭제 후 다시 추가할 때 같은 id를 재사용하지 않는다).
        usedCardIDs.formUnion(layout.cards.map(\.id))
        // 저장된 배치에 없는 카드의 실행 상태는 버린다(지운 카드가 되살아난 것처럼 보이지 않게).
        pruneCardStates(keeping: layout.cards)
        logLayout("save")
        rebuildDisplay()
        onLayoutChange?()
    }

    /// 저장된 배치에 없는 카드 id의 실행 상태를 버린다.
    private func pruneCardStates(keeping cards: [DockCardSpec]) {
        let kept = Set(cards.map(\.id))
        let removed = timerStates.keys.filter { !kept.contains($0) }
        guard !removed.isEmpty else { return }
        for id in removed { timerStates[id] = nil }
        stateLog?.appendEvent("card=prune removed=\(removed.sorted().joined(separator: ","))")
    }

    /// 편집창에서 배치를 **미리** 바꾼다(디스크에는 쓰지 않는다).
    func previewLayoutChange(_ next: DockLayout) {
        previewLayout = next
        logLayout("preview")
        rebuildDisplay()
        onLayoutChange?()
    }

    /// 미리보기를 버리고 저장된 배치로 돌아간다(취소·창 닫기).
    func discardLayoutPreview() {
        guard previewLayout != nil else { return }
        previewLayout = nil
        stateLog?.appendEvent("layout=preview result=discarded")
        rebuildDisplay()
        onLayoutChange?()
    }

    /// 배치 저장 요청. AppDelegate가 설정 파일에 쓰고 성공 여부를 돌려준다.
    var onSaveLayout: ((DockLayout) -> (message: String, succeeded: Bool))?

    /// 미리보기 배치를 저장한다. **성공 여부를 돌려준다.**
    @discardableResult
    func saveLayoutPreview() -> Bool {
        guard let previewLayout else { return true }
        let result = onSaveLayout?(previewLayout)
            ?? (message: "저장할 수 없습니다: 설정을 쓸 수 없습니다", succeeded: false)
        editorNotice = result.message
        stateLog?.appendEvent("layout=save result=\(result.succeeded ? "ok" : "failed")")
        if result.succeeded { self.previewLayout = nil }
        return result.succeeded
    }

    // MARK: - 카드 실행 상태 (메모리 전용)

    /// 카드 id의 타이머 상태. 없으면 처음 상태(가득 찬 25분, 멈춤)다.
    func timerState(for cardID: String) -> FocusTimerState {
        timerStates[cardID] ?? FocusTimerState(duration: timerDuration)
    }

    /// 타이머 기본 시간(초). 진단용 재정의가 없으면 제품 기본값(25분)이다.
    func setTimerDuration(_ seconds: Int) {
        timerDuration = TimeInterval(seconds)
        stateLog?.appendEvent("timer=duration seconds=\(seconds)")
    }

    /// 타이머 조작. **마우스와 키보드가 같은 경로**로 들어온다.
    func performTimer(_ action: DockTimerAction, cardID: String, source: ActionSource = .mouse) {
        var state = timerState(for: cardID)
        switch action {
        case .start: state.start(at: now)
        case .pause: state.pause(at: now)
        case .reset: state.reset()
        }
        timerStates[cardID] = state
        stateLog?.appendEvent(
            "card=\(cardID) action=\(action.rawValue) source=\(source.rawValue) "
                + "remaining=\(state.text(at: now)) running=\(state.isRunning(at: now))"
        )
    }

    /// 00:00에 도달한 타이머를 **완료 상태로 확정**한다(실행 중 표시가 남지 않게).
    /// 남은 시간은 시각으로 계산하므로, 조회가 밀려도 이 판정은 정확하다.
    private func completeFinishedTimers() {
        for card in effectiveLayout.cards where card.kind == .focusTimer {
            guard let state = timerStates[card.id],
                  state.isRunning,
                  state.isFinished(at: now) else { continue }
            var completed = state
            completed.complete(at: now)
            timerStates[card.id] = completed
            stateLog?.appendEvent("card=\(card.id) action=complete remaining=00:00 running=false")
        }
    }

    // MARK: - 보조 메뉴 (⋯)

    /// `⋯` 보조 메뉴가 떠 있는가. 그동안은 **키 입력을 가로채지 않는다**(메뉴가 Enter/Esc를 받아야 한다).
    private(set) var isMenuTracking = false

    /// `⋯` 보조 메뉴가 뜰 자리(화면 좌표가 아니라 **창 안 좌표**). 화면이 알려준다.
    private var menuAnchor: CGRect = .zero

    /// 화면에서 `⋯` 버튼 위치를 알려준다(키보드로 열 때 같은 자리에 띄우기 위해).
    func reportMenuAnchor(_ rect: CGRect) { menuAnchor = rect }

    /// 보조 메뉴를 띄운다. **마우스와 키보드가 같은 메뉴·같은 실행 경로를 쓴다.**
    func showActionMenu(source: ActionSource = .mouse) {
        stateLog?.appendEvent("menu=open source=\(source.rawValue)")
        let menu = NSMenu()
        menu.autoenablesItems = false
        addMenuItem(menu, title: isDetailsVisible ? "상세 보기 닫기" : "상세 보기 열기", enabled: true) {
            self.toggleDetails()
        }
        menu.addItem(.separator())
        addMenuItem(menu, title: "현재 폴더 열기", enabled: state.canOpenFolder) {
            self.perform(.openFolder, source: .menu)
        }
        addMenuItem(menu, title: "현재 경로 복사", enabled: state.canCopyPath) {
            self.perform(.copyPath, source: .menu)
        }
        menu.addItem(.separator())
        addMenuItem(menu, title: state.isLocked ? "고정 해제" : "표시 대상 고정", enabled: true) {
            self.toggleLock()
        }
        if display.isSpaceShort {
            menu.addItem(.separator())
            addMenuItem(
                menu,
                title: "공간 부족 — 배치가 화면보다 \(Int(display.demandWidth - display.barWidth))pt 넓습니다",
                enabled: true
            ) {
                self.showDetails()
            }
        }

        let point = screenPoint(forMenuAnchor: menuAnchor)
        // 메뉴가 떠 있는 동안에는 **키 입력을 우리가 가로채지 않는다**(메뉴가 Enter/Esc를 받아야 한다).
        isMenuTracking = true
        defer { isMenuTracking = false }
        menu.popUp(positioning: nil, at: point, in: nil)
        stateLog?.appendEvent("menu=close source=\(source.rawValue)")
    }

    private func addMenuItem(
        _ menu: NSMenu,
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
        let target = MenuActionTarget(action)
        item.target = target
        item.isEnabled = enabled
        // 메뉴가 닫힌 뒤에도 대상이 살아 있게 메뉴가 붙잡는다.
        item.representedObject = target
        menu.addItem(item)
    }

    /// 창 안 좌표(SwiftUI 전역, 왼쪽 위 기준) → 화면 좌표(NSMenu가 쓰는 좌표).
    private func screenPoint(forMenuAnchor rect: CGRect) -> NSPoint {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else {
            return NSEvent.mouseLocation
        }
        let inWindow = NSPoint(x: rect.minX, y: content.bounds.height - rect.maxY)
        let inScreen = window.convertPoint(toScreen: inWindow)
        // 메뉴가 버튼 아래로 펼쳐지게 조금 내린다.
        return NSPoint(x: inScreen.x, y: inScreen.y - 4)
    }

    // MARK: - 편집창의 배치 조작 (저장 전에는 미리보기)

    /// 편집창에서 배치를 바꾼다. 순서는 항상 **모든 구성요소를 한 번씩** 담고, 영역 폭은 승인 범위로 자른다.
    private func mutateLayout(_ mutate: (inout DockLayout) -> Void) {
        var next = effectiveLayout
        mutate(&next)
        var order = next.order.reduce(into: [DockComponent]()) { accumulated, item in
            if !accumulated.contains(item) { accumulated.append(item) }
        }
        for item in DockComponent.allCases where !order.contains(item) { order.append(item) }
        next.order = order
        next.projectAreaWidth = min(
            max(next.projectAreaWidth, DockLayout.minimumProjectAreaWidth),
            DockLayout.maximumProjectAreaWidth
        )
        previewLayoutChange(next)
    }

    /// 구성요소(공통·카드·프로젝트 영역) 순서를 한 칸 옮긴다.
    func editorMoveComponent(_ component: DockComponent, by offset: Int) {
        mutateLayout { layout in
            guard let index = layout.order.firstIndex(of: component) else { return }
            let target = index + offset
            guard layout.order.indices.contains(target) else { return }
            layout.order.swapAt(index, target)
        }
    }

    /// 프로젝트 영역 폭(항목 수와 무관하게 유지되는 값).
    func editorSetProjectAreaWidth(_ width: Double) {
        mutateLayout { $0.projectAreaWidth = width }
    }

    /// 카드 추가. 같은 종류를 여러 개 두어도 id로 구분하고, **지운 카드의 id는 다시 쓰지 않는다**.
    func editorAddCard(_ kind: DockCardKind) {
        let card = DockCardSpec.makeDefault(kind, usedIDs: usedCardIDs)
        usedCardIDs.insert(card.id)
        mutateLayout { $0.cards.append(card) }
    }

    /// 카드 제거. 실행 상태는 id로 분리돼 있고 **지우지 않는다**(같은 id가 다시 오면 이어진다).
    func editorRemoveCard(_ id: String) {
        mutateLayout { $0.cards.removeAll { $0.id == id } }
    }

    func editorMoveCard(_ id: String, by offset: Int) {
        mutateLayout { layout in
            guard let index = layout.cards.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard layout.cards.indices.contains(target) else { return }
            layout.cards.swapAt(index, target)
        }
    }

    private func logLayout(_ phase: String) {
        let layout = effectiveLayout
        let cards = layout.cards.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ",")
        stateLog?.appendEvent(
            "layout=\(phase) order=\(layout.order.map(\.rawValue).joined(separator: ",")) area=\(Int(layout.projectAreaWidth)) cards=\(cards.isEmpty ? "-" : cards)"
        )
    }

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
    /// 카드(시계·타이머) 표시용 1초 타이머. 조회 주기와 별개다.
    private var clockTimer: Timer?
    /// 타이머 기본 시간(초). 제품 기본값은 25분이고, 진단용으로만 바뀐다.
    private var timerDuration: TimeInterval = FocusTimerState.defaultDuration
    private let stateLog: StateLog?

    /// 사용자가 명시적으로 Dock을 호출한 상태인지.
    private var isDockInvoked = false
    /// 마지막 조회 시점에 **현재 대상이 포커스 확인을 받은 적 있는지**.
    /// 판정 불가일 때 "마지막으로 확인한 대상"이라고 말해도 되는지 판단하는 데 쓴다.
    private var confirmedTarget = true
    /// 마지막으로 창 크기를 맞췄을 때의 바 폭(불필요한 리사이즈를 피한다).
    private var lastBarWidth: CGFloat = 0
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
        // 카드(시계·타이머)는 **조회 주기와 무관하게** 1초마다 갱신한다.
        // 남은 시간은 이 값과 시작 시각으로 계산하므로 갱신이 밀려도 값이 맞는다.
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                // 00:00에 도달한 타이머는 여기서 완료로 확정한다(실행 중 표시가 남지 않게).
                self.completeFinishedTimers()
            }
        }
        now = Date()
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
        rebuildDisplay()
        refreshRunningApps()
        // 바 폭이 달라졌으면 창 크기도 다시 맞춘다(프로젝트 **항목 수**로는 달라지지 않는다).
        if display.barWidth != lastBarWidth {
            lastBarWidth = display.barWidth
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
            project: resolution.hasProject ? "\(resolution.projectID)(\(resolution.allItems.count))" : "-",
            // 화면·숨김·키보드가 같은 목록을 쓰는지 로그만 보고 확인할 수 있게 남긴다.
            shown: displaySummary
        )
    }

    /// 실행 중인 빌드(번들 정보에서 읽는다 — 개발용 실행 파일이면 번들 정보가 없다).
    let build = BuildIdentity.from(infoDictionary: Bundle.main.infoDictionary)

    /// 지금 패널 상태(화면·표시 목록·키보드가 **같은 판정**을 쓴다).
    var panelStatus: DockPanelStatus {
        DockPanelStatus.from(state: state, hasProject: resolution.hasProject)
    }

    /// 표시 목록을 다시 만든다. **화면·숨김 개수·키보드 이동이 모두 이 결과를 쓴다.**
    private func rebuildDisplay() {
        let next = DockDisplayBuilder.make(
            resolution: resolution,
            layout: effectiveLayout,
            screenWidth: ScreenGeometry.fallbackFrame.width,
            // 가짜 모드 표시도 바 폭을 차지한다 → 기하 계산에 함께 넣는다.
            showsFakeBadge: isFake,
            // 표시 방식(아이콘+이름/아이콘 중심)이 타일 폭·개수를 정한다.
            labelMode: effectiveAppearance.labelMode,
            // 확인 중·오류에는 패널이 사유만 보여준다 → 표시 목록도 같은 대상을 가리키게 한다.
            showsProjectItems: panelStatus == .registered || panelStatus == .unregistered
        )
        guard next != display else { return }
        display = next
        stateLog?.appendEvent(
            "display shown=\(next.visibleItemCount) hidden=\(next.hiddenItemCount) "
                + "common=\(next.common.count)/\(next.commonHidden) project=\(next.project.count)/\(next.projectHidden) "
                + "area=\(Int(next.projectAreaWidth)) bar=\(Int(next.barWidth)) short=\(next.isSpaceShort)"
        )
    }

    /// 로그 한 줄에 남길 표시 요약(화면 목록 그대로).
    private var displaySummary: String {
        let refs = display.order.map { $0.item.isCommon ? "c:\($0.ref.itemID)" : "p:\($0.ref.itemID)" }
        return "shown=\(display.visibleItemCount) hidden=\(display.hiddenItemCount) "
            + "area=\(Int(display.projectAreaWidth)) bar=\(Int(display.barWidth)) "
            + "list=[\(refs.joined(separator: ","))]"
    }

    /// 실행 중인 앱 번들 경로를 갱신한다(앱 타일의 실행 중 표시).
    private func refreshRunningApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        if running != runningAppPaths { runningAppPaths = running }
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

    /// 사용자에게 보여줄 결과 문구를 넣는다(모드 적용·복원 결과 등).
    func setActionMessage(_ message: String) {
        actionMessage = message
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

    /// 지금 화면에서 이동할 수 있는 것들. **표시 목록·배치 순서와 같은 기준**으로 만든다(코어 `DockFocusPlan`).
    ///
    /// 항목 타일뿐 아니라 타이머 버튼·밀린 항목(`+N`)·등록(`+`)·오른쪽 `⋯` 메뉴까지 포함한다.
    var focusItems: [FocusItem] {
        DockFocusPlan.controls(
            display: display,
            layout: effectiveLayout,
            allItems: resolution.allItems,
            detailsVisible: isDetailsVisible,
            // 화면·표시 목록과 **같은 판정**을 쓴다(작업 상태 우선).
            panelStatus: panelStatus
        )
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

    /// 진단용: 호출 세션을 열고 **키보드 경로를 순서대로** 실행한다(초점 이동 → 활성화).
    ///
    /// macOS는 다른 앱이 앞에 있을 때 **합성 키 이벤트로 이 앱을 활성화하지 못하게** 한다.
    /// 그래서 실제 키 입력 대신, 키가 들어왔을 때 타는 **같은 함수**(`moveFocus`·`activateFocusedItem`)를
    /// 순서대로 불러 초점 목록과 조작 연결을 확인한다.
    func runKeyboardSelfTest() {
        setDockInvoked(true)
        stateLog?.appendEvent("keyselftest list=[\(focusItems.map(\.label).joined(separator: ","))]")

        func focusAndActivate(matching match: (FocusItem) -> Bool, label: String) -> Bool {
            for _ in 0..<max(4, focusItems.count + 2) {
                if let current = focusedItem, match(current) {
                    stateLog?.appendEvent("keyselftest target=\(label) at=\(current.label)")
                    activateFocusedItem()
                    return true
                }
                moveFocus(forward: true)
            }
            stateLog?.appendEvent("keyselftest target=\(label) result=not-found")
            return false
        }

        _ = focusAndActivate(matching: { if case .timer(_, .start) = $0 { return true }; return false }, label: "timer.start")
        _ = focusAndActivate(matching: { if case .timer(_, .pause) = $0 { return true }; return false }, label: "timer.pause")
        _ = focusAndActivate(matching: { if case .timer(_, .reset) = $0 { return true }; return false }, label: "timer.reset")
        _ = focusAndActivate(matching: { if case .overflow = $0 { return true }; return false }, label: "overflow")
        stateLog?.appendEvent("keyselftest done details=\(isDetailsVisible)")
        setDockInvoked(false)
    }

    // MARK: - Dock 편집 (초안 → 저장/취소)

    /// 편집을 시작한다. 범위를 지정하지 않으면 **지금 표시 중인 대상**을 고른다.
    /// 이후 포커스가 바뀌어도 이 범위는 바뀌지 않는다.
    func beginEditing(scope: ItemScope? = nil) {
        // 편집을 시작할 때 **상세 보기는 접는다**(편집창과 겹쳐 화면이 복잡해지지 않게).
        hideDetails()
        // 편집창은 **지금 저장된 외형·배치**에서 시작한다(미리보기는 열 때 초기화).
        previewAppearance = nil
        previewLayout = nil
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
        // 미리보기 외형·배치도 버린다(저장한 값으로 돌아간다).
        discardAppearancePreview()
        discardLayoutPreview()
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

    /// 편집창의 **저장**: 모양 미리보기·배치 미리보기·항목 초안을 함께 저장한다.
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
        // 배치도 같은 규칙이다. 값이 같으면 설정 파일을 건드리지 않는다.
        if let preview = previewLayout {
            if preview == layout {
                unchanged.append("배치")
                previewLayout = nil
            } else if saveLayoutPreview() {
                saved.append("배치")
            } else {
                failed.append("배치")
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
        case .item(let ref): performItem(ref: ref, source: .keyboard)
        case .timer(let cardID, let action): performTimer(action, cardID: cardID, source: .keyboard)
        case .overflow: showDetails()
        case .projectAdd: openEditor()
        case .projectOpenFolder:
            // 화면 버튼과 **같은 검증 경로**(isAllowed + DockActionPlanner)를 쓴다.
            perform(.openFolder, source: .keyboard)
        case .registerProject: openEditor()
        case .menu: showActionMenu(source: .keyboard)
        case .details: toggleDetails()
        case .hide: hideWindow()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    /// 호출 직후의 첫 선택. **화면에 있는 것 중에서만** 고른다.
    /// (화면에서 빠진 조작을 고르면 호출 직후 Enter가 보이지 않는 동작을 실행한다.)
    private func firstAvailableItem() -> FocusItem {
        focusItems.first ?? .details
    }

    // MARK: - 항목 실행 (앱·폴더·링크)

    /// 항목을 실행한다. 마우스와 키보드가 **같은 검증 경로**(`DockItemActionPlanner`)를 쓴다.
    ///
    /// 범위 + ID로 대상을 찾으므로 목록 순서가 바뀌어도 다른 항목이 실행되지 않는다.
    func performItem(ref: DockItemRef, source: ActionSource = .mouse) {
        guard let target = resolution.allItems.first(where: { $0.itemID == ref.itemID && $0.scopeID == ref.scopeID }) else {
            actionMessage = "선택한 항목을 현재 표시에서 찾을 수 없습니다"
            stateLog?.appendEvent("item=\(ref.label) source=\(source.rawValue) result=missing")
            return
        }
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
