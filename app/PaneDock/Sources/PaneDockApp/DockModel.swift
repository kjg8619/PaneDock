import AppKit
import Combine
import FocusProbeCore
import Foundation

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
        case link(Int)
        case openFolder
        case copyPath
        case lock
        case hide
        case quit

        var label: String {
            switch self {
            case .link(let index): return "link:\(index)"
            case .openFolder: return "openFolder"
            case .copyPath: return "copyPath"
            case .lock: return "lock"
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
    /// 현재 표시 대상에 해당하는 프로젝트. 없으면 기본 Dock으로 동작한다.
    @Published private(set) var project: ProjectResolution?
    /// 설정 파일 관련 안내(손상·미래 버전 등). 없으면 nil.
    @Published private(set) var settingsNotice: String?
    /// 프로젝트 설정 상태 안내(다시 읽기 결과·경고). 없으면 nil.
    @Published private(set) var catalogNotice: String?

    /// 창 숨기기 요청. AppDelegate가 처리한다.
    var onHide: (() -> Void)?

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
    /// 호출 직전에 마지막으로 확인한 "바깥 앱 최전면" 값.
    /// 호출 중에는 이 값으로 고정해, **우리 자신의 활성화를 작업 위치 이동으로 해석하지 않는다.**
    private var frozenHostFrontmost: Bool?

    init(adapter: GhosttyAdapter, isFake: Bool, stateLogPath: String? = nil) {
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.failureText = failure
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
            hostFrontmostOverride: isDockInvoked ? frozenHostFrontmost : nil
        )
        // 화면에 반영한 것과 **같은 값**을 실행 대상으로 고정한다.
        actionInfo = lock.info ?? effectiveCurrent
        // 프로젝트 판정도 **화면에 반영한 CWD**로만 만든다.
        // 표시된 링크와 실행 대상이 어긋나지 않게 하기 위해서다.
        project = actionInfo?.reportedCWD.flatMap {
            ProjectResolver.resolve(cwd: $0, catalog: catalog, catalogDiagnostics: catalogDiagnostics)
        }
        stateLog?.append(
            refresh: refreshCount,
            display: state.display.rawValue,
            folderName: state.folderName,
            fullPath: state.fullPath ?? "-",
            paneID: state.paneID ?? "-",
            locked: state.isLocked,
            project: project.map { "\($0.projectID)(\($0.links.count))" } ?? "-"
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
        let previousProject = project
        self.catalog = catalog
        self.catalogDiagnostics = diagnostics
        catalogNotice = note
        rebuildState()

        if case .link = focusedItem, !ProjectSelection.selectionSurvives(reloadFrom: previousProject, to: project) {
            focusedItem = nil
            stateLog?.appendEvent("selection=cancelled (catalog changed)")
        }
        stateLog?.appendEvent(
            "catalog projects=\(catalog.projects.count) diagnostics=\(diagnostics.count) notice=\(note?.replacingOccurrences(of: "\n", with: " / ") ?? "-")"
        )
    }

    /// 지금 화면에서 이동할 수 있는 항목들. 링크가 먼저, 고정 버튼이 뒤에 온다.
    var focusItems: [FocusItem] {
        var items: [FocusItem] = []
        if let project {
            for index in project.links.indices {
                items.append(.link(index))
            }
        }
        items.append(contentsOf: [.openFolder, .copyPath, .lock, .hide, .quit])
        return items
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
        case .link(let index): openLink(at: index, source: .keyboard)
        case .openFolder: perform(.openFolder, source: .keyboard)
        case .copyPath: perform(.copyPath, source: .keyboard)
        case .lock: toggleLock()
        case .hide: hideWindow()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    private func firstAvailableItem() -> FocusItem {
        if let project, !project.links.isEmpty { return .link(0) }
        if state.canOpenFolder { return .openFolder }
        if state.canCopyPath { return .copyPath }
        return .lock
    }

    // MARK: - 프로젝트 링크 실행

    /// 링크를 연다. 마우스와 키보드가 **같은 검증 경로**(`ProjectActionPlanner`)를 쓴다.
    func openLink(at index: Int, source: ActionSource = .mouse) {
        guard let project, project.links.indices.contains(index) else {
            actionMessage = "선택한 링크를 현재 표시에서 찾을 수 없습니다"
            stateLog?.appendEvent("link=\(index) source=\(source.rawValue) result=missing")
            return
        }
        // 표시된 묶음에서 항목을 확정한다. 선택 중 프로젝트가 바뀌면 planner가 거부한다.
        let target = project.links[index]
        switch ProjectActionPlanner.plan(target: target, in: project, state: state) {
        case .openURL(let url):
            // 로그에는 쿼리·프래그먼트를 뺀 형태만 남긴다(토큰 노출 방지).
            stateLog?.appendEvent(
                "link=\(target.linkID) project=\(target.projectID) source=\(source.rawValue) result=allowed url=\(ProjectLinkPrivacy.redactedForLog(target.url))"
            )
            let opened = NSWorkspace.shared.open(url)
            actionMessage = opened ? "링크를 열었습니다: \(target.name)" : "링크를 열지 못했습니다: \(target.url)"
        case .reject(let reason):
            stateLog?.appendEvent(
                "link=\(target.linkID) project=\(target.projectID) source=\(source.rawValue) result=rejected reason=\(reason)"
            )
            actionMessage = reason
        }
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
