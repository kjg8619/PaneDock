import AppKit
import FocusProbeCore
import SwiftUI

/// 창과 메뉴 막대 항목, 전역 단축키, 설정 저장을 소유한다.
///
/// **스스로를 활성화하지 않는다(호출 시 제외).**
/// - 평소: 창은 non-activating panel이라 클릭해도 앱이 활성화되지 않는다.
///   그래야 PaneDock 조작이 새로운 작업 위치로 해석되지 않는다.
/// - 호출했을 때만: 키보드 입력을 받기 위해 활성화한다. 그동안은 모델이
///   "바깥 앱 최전면" 값을 호출 직전 값으로 고정하므로 추적 대상은 바뀌지 않는다.
/// - 닫을 때: **Ghostty를 강제로 활성화하지 않는다.** 사용자가 다른 앱으로 이동한 의도를 존중한다.
@MainActor
final class PaneDockAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: LaunchOptions
    private var panel: NSPanel?
    /// Dock 편집창. 작은 Dock과 달리 **일반 창**이다(폼이 들어간다).
    private var editorWindow: NSWindow?
    /// 지금 창 크기를 맞추는 중인지. 이때 생기는 이동은 사용자의 위치가 아니므로 저장하지 않는다.
    private var isApplyingLayout = false
    /// 자동 접기 예약. **늦게 도착한 타이머**가 새로 펼친 Dock을 접지 못하게 토큰으로 막는다.
    private let collapseScheduler = CollapseScheduler()
    private var collapseWork: DispatchWorkItem?
    /// 사용자가 명시적으로 숨긴 상태(자동 접기와 구분한다). 숨긴 Dock은 타이머가 다시 띄우지 않는다.
    private var isUserHidden = false
    /// 마우스 버튼을 놓는 순간을 우리 앱 안에서만 본다(전역 감시 아님).
    private var mouseUpMonitor: Any?
    /// 프로그램이 마지막으로 크기를 맞춘 시각. 알림이 늦게 도착하는 경우까지 막는다.
    private var lastProgrammaticLayout: Date?
    private var statusItem: NSStatusItem?
    private var model: DockModel?
    private var settings: SettingsStore?
    private var catalogStore: ProjectCatalogStore?
    /// 마지막으로 **적용에 성공한** 구성. 실패 시 이 구성을 유지한다.
    private var appliedCatalog = ProjectCatalog()
    private var appliedDiagnostics: [String] = []
    private var hotKey: GlobalHotKey?
    private var hotKeyRegistration: GlobalHotKey.Registration = .disabled
    private var keyMonitor: Any?
    private var pendingPositionSave: DispatchWorkItem?
    private var startupNotice = ""

    nonisolated init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = makeSettingsStore()
        settings = store

        let model = DockModel(
            adapter: makeHostAdapter(options),
            isFake: options.isFake,
            stateLogPath: options.stateLogPath
        )
        model.onHide = { [weak self] in self?.hidePanel() }
        // 상세 보기 토글·프로젝트 변경으로 크기가 달라지면 창을 다시 맞춘다.
        model.onLayoutChange = { [weak self] in self?.applyPanelSize() }
        // Dock 편집: 별도 창을 띄우고, 저장은 **사용자가 저장을 눌렀을 때만** 파일에 쓴다.
        model.onOpenEditor = { [weak self] in self?.openEditor() }
        // 외형 저장: 설정 파일에만 쓴다(projects.json은 건드리지 않는다).
        model.onSaveAppearance = { [weak self] appearance in
            guard let self, let settings = self.settings else {
                return (message: "저장할 수 없습니다: 설정 저장소를 열지 못했습니다", succeeded: false)
            }
            if let reason = settings.writeBlockedReason {
                return (message: "모양을 저장하지 않았습니다: \(reason)", succeeded: false)
            }
            // 파일에 실제로 써진 경우에만 성공으로 보고한다(쓰기 실패를 "저장했습니다"로 보이지 않게).
            guard settings.update({ $0.appearance = appearance }) else {
                return (message: "모양을 저장하지 못했습니다: 설정 파일에 쓰지 못했습니다", succeeded: false)
            }
            self.model?.applyAppearance(appearance)
            return (message: "모양을 저장했습니다.", succeeded: true)
        }
        model.onCloseEditor = { [weak self] in self?.closeEditor() }
        model.onSaveDraft = { [weak self] catalog in
            guard let self else { return (message: "저장할 수 없습니다", succeeded: false) }
            return self.saveDraft(catalog, model: model)
        }
        let catalogStore = makeCatalogStore()
        self.catalogStore = catalogStore
        applyCatalog(to: model, from: catalogStore, isReload: false)

        startupNotice = [
            settingsNotice(for: store.outcome),
            duplicateInstanceNotice(),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        model.setSettingsNotice(startupNotice.isEmpty ? nil : startupNotice)
        self.model = model

        // 저장된 외형을 반영하고 시작한다(없던 설정이면 기본 외형).
        model.applyAppearance(store.settings.appearance)
        let panel = makePanel(model: model)
        panel.delegate = self
        self.panel = panel

        // 진단용: 상세 보기를 연 상태로 시작한다(창 크기도 함께 맞춘다).
        if options.detailsAtLaunch {
            model.showDetails()
        }
        if options.editorAtLaunch {
            openEditor()
        }
        // 진단용: 편집 초안에 앱·폴더·링크를 넣고 순서를 바꾼 뒤 **저장까지** 해 본다(임시 카탈로그 전용).
        if let delay = options.editorSelfTestAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                guard let self, let model = self.model else { return }
                model.beginEditing(scope: .common)
                // 1) 실제 설치된 앱
                model.editorBeginAdd(kind: .app)
                model.editorUpdateForm(name: "터미널", target: "/System/Applications/Utilities/Terminal.app")
                model.editorCommitForm()
                // 2) 고정 폴더
                model.editorBeginAdd(kind: .folder)
                model.editorUpdateForm(name: "스크래치", target: "/tmp")
                model.editorCommitForm()
                // 3) 웹 링크
                model.editorBeginAdd(kind: .link)
                model.editorUpdateForm(name: "예시", target: "https://example.com/v15")
                model.editorCommitForm()
                // 4) 순서 바꾸기(키보드 이동) — 맨 아래 링크를 한 칸 위로
                if let last = model.draft?.items.last?.id {
                    model.editorMove(last, by: -1)
                }
                model.saveDraft()
                model.appendEvent("editor-selftest save done items=\(model.draft?.items.count ?? -1)")
            }
        }
        // 진단용: 편집만 하고 **취소**하면 저장된 구성이 바뀌지 않는지 확인한다.
        if let delay = options.editorCancelAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                guard let self, let model = self.model else { return }
                model.beginEditing(scope: .common)
                model.editorBeginAdd(kind: .folder)
                model.editorUpdateForm(name: "취소될 항목", target: "/tmp")
                model.editorCommitForm()
                model.cancelEditing()
                model.appendEvent("editor-selftest cancel done")
            }
        }

        // 마우스 버튼을 놓으면(드래그·클릭 종료) 접기 조건을 다시 본다. 앱 안에서만 받는다.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            self?.scheduleCollapseCheck()
            return event
        }
        installStatusItem(model: model)
        installHotKey(model: model)
        model.start(intervalMilliseconds: options.intervalMilliseconds)

        if options.hidden {
            panel.orderOut(nil)
        } else {
            // 시작할 때는 활성화하지 않는다. 창만 올린다.
            panel.orderFrontRegardless()
        }

        persistCorrectedOriginIfNeeded()
        logStartup()

        // 진단용 창 이동. 사용자가 헤더를 드래그한 것과 같은 저장 경로(windowDidMove)를 탄다.
        if let target = options.moveTo {
            panel.setFrameOrigin(target)
        }

        // 진단용 다시 읽기. **메뉴 항목의 target/action을 그대로 호출**해 메뉴 배선까지 지나간다.
        if let delay = options.reloadAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                guard let self else { return }
                let invoked = self.performMenuItem(titled: "프로젝트 설정 다시 읽기")
                self.model?.appendEvent("menu-invoke title=프로젝트 설정 다시 읽기 result=\(invoked)")
            }
        }
    }

    /// 저장 좌표가 화면 밖이어서 보정했으면, 보정된 좌표를 저장한다.
    /// 손상·미래 버전처럼 저장된 좌표가 없는 경우에는 아무것도 쓰지 않는다.
    private func persistCorrectedOriginIfNeeded() {
        guard let panel, let settings, settings.canWrite,
              let stored = settings.settings.windowOrigin else { return }
        let origin = panel.frame.origin
        guard stored.x != Double(origin.x) || stored.y != Double(origin.y) else { return }
        settings.update {
            $0.windowOrigin = StoredOrigin(x: Double(origin.x), y: Double(origin.y))
        }
    }

    /// 다른 인스턴스가 실행 중이면 알린다.
    ///
    /// Carbon `RegisterEventHotKey`는 **프로세스 간 중복 등록을 알려주지 않는다**(실측).
    /// 두 인스턴스가 모두 "등록됨"이라고 보고하지만 실제로 키를 받는 쪽은 하나뿐이므로,
    /// 여기서 직접 감지해 안내한다.
    private func duplicateInstanceNotice() -> String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return nil }
        return "다른 PaneDock 인스턴스 \(others.count)개가 실행 중입니다. 호출 단축키는 한쪽에서만 동작합니다."
    }

    /// 상태바 메뉴에서 제목으로 항목을 찾아 **그 항목의 target/action을 그대로 호출**한다.
    ///
    /// 실제 클릭 이벤트는 아니지만, 메뉴 배선(항목 존재·target·selector)을 그대로 지나간다.
    @discardableResult
    private func performMenuItem(titled title: String) -> Bool {
        guard let menu = statusItem?.menu,
              let item = menu.items.first(where: { $0.title == title }),
              let action = item.action
        else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    /// 메뉴 구성를 로그에 남긴다(창을 보지 않고 항목 존재·활성 여부를 확인할 수 있게).
    private func menuSummary() -> String {
        guard let menu = statusItem?.menu else { return "-" }
        return menu.items
            .filter { !$0.isSeparatorItem }
            .map { "\($0.title)\($0.isEnabled ? "" : "(비활성)")" }
            .joined(separator: " | ")
    }

    /// 시작 상태를 한 줄로 남긴다. 화면을 읽지 않고도 모드·설정·단축키 등록 결과를 확인할 수 있다.
    private func logStartup() {
        let store = settings
        let mode = options.isFake ? "fake" : "live"
        let file = store?.fileURL?.path ?? "(메모리 전용)"
        let outcome = store?.outcome.label ?? "-"
        let hotKey = (store?.settings.hotKeyEnabled ?? false)
            ? (store?.settings.hotKey.displayName ?? "-")
            : "사용 안 함"
        let frame = panel?.frame ?? .zero
        let notice = startupNotice.isEmpty ? "-" : startupNotice.replacingOccurrences(of: "\n", with: " / ")
        let catalog = catalogStore.map { "\($0.outcome.label) projects=\($0.catalog.projects.count) diagnostics=\($0.diagnostics.count)" } ?? "-"
        let line = "PaneDock startup: mode=\(mode) adapter=\(options.hostSource.rawValue) settings=\(outcome) file=\(file) "
            + "catalog=\(catalog) "
            + "origin=(\(Int(frame.origin.x)),\(Int(frame.origin.y))) size=\(Int(frame.width))x\(Int(frame.height)) "
            + "appearance=\(model?.effectiveAppearance.size.rawValue ?? "-")/\(model?.effectiveAppearance.labelMode.rawValue ?? "-")/\(model?.effectiveAppearance.colorMode.rawValue ?? "-")/\(model?.effectiveAppearance.displayMode.rawValue ?? "-") "
            + "panel=\(Int(panel?.frame.width ?? 0))x\(Int(panel?.frame.height ?? 0)) "
            + "panelAppearance=\(panel?.appearance?.name.rawValue ?? "nil") "
            + "hotKey=\(hotKey) hotKeyStatus=\(hotKeyRegistration.message) notice=\(notice)\n"
            + "PaneDock menu: \(menuSummary())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 설정

    private func makeSettingsStore() -> SettingsStore {
        // 명시적 경로 재정의는 가짜 모드에서도 존중한다(온도 시험용 임시 파일).
        // 기본 경로는 절대 쓰지 않는다.
        if let override = options.settingsPath {
            return SettingsStore(url: URL(fileURLWithPath: override))
        }
        // 가짜 데이터 모드는 실제 사용자 설정을 건드리지 않는다.
        if options.isFake {
            return SettingsStore(url: nil)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PaneDock", isDirectory: true)
            .appendingPathComponent("settings.json")
        return SettingsStore(url: base)
    }

    private func settingsNotice(for outcome: SettingsLoadOutcome) -> String? {
        switch outcome {
        case .fresh, .loaded:
            return nil
        case .corrupt(let backupPath):
            let where_ = backupPath.map { "원본은 \($0)으로 보존했습니다." } ?? "원본 백업에 실패했습니다."
            return "설정 파일을 읽을 수 없어 기본값으로 시작했습니다. \(where_)"
        case .unsupportedVersion(let found):
            return "설정 스키마 버전 \(found)은 이 버전이 지원하지 않습니다. 파일을 건드리지 않고 기본값으로 실행합니다."
        }
    }

    /// 프로젝트 카탈로그는 **읽기만** 한다. 앱이 사용자 파일을 덮어쓰지 않는다.
    private func makeCatalogStore() -> ProjectCatalogStore {
        ProjectCatalogStore(url: projectCatalogURL(for: options))
    }

    /// 카탈로그를 하나의 일관된 구성으로 반영한다.
    ///
    /// - 정상 로딩(fresh·loaded): 새 구성을 적용하고 현재 CWD 기준으로 다시 계산한다.
    /// - 치명적 실패(corrupt·unsupportedVersion): **이전 정상 구성을 유지**하고 그 사실을 알린다.
    /// - 어느 경우에도 사용자 파일을 고치지 않는다.
    private func applyCatalog(to model: DockModel, from store: ProjectCatalogStore, isReload: Bool) {
        let application = ProjectCatalogApplier.apply(
            load: store.outcome,
            loadedCatalog: store.catalog,
            loadedDiagnostics: store.diagnostics,
            previousCatalog: appliedCatalog,
            previousDiagnostics: appliedDiagnostics,
            isReload: isReload
        )
        appliedCatalog = application.catalog
        appliedDiagnostics = application.diagnostics
        model.updateCatalog(application.catalog, diagnostics: application.diagnostics, note: application.note)
    }

    @MainActor @objc private func openEditorAction() {
        openEditor()
    }

    @MainActor @objc private func reloadCatalogAction() {
        guard let model, let store = catalogStore else { return }
        store.reload()
        applyCatalog(to: model, from: store, isReload: true)
        stateLogLine("reload catalog outcome=\(store.outcome.label) projects=\(store.catalog.projects.count) diagnostics=\(store.diagnostics.count)")
    }

    /// 다시 읽기 결과를 상태 로그에도 남긴다(창을 보지 않고 확인할 수 있게).
    private func stateLogLine(_ text: String) {
        model?.appendEvent(text)
    }

    // MARK: - 창

    /// 지금 내용에 맞는 창 크기. **접힘·창 생성·레이아웃이 모두 이 함수 하나를 쓴다** —
    /// 같은 계산을 두 곳에 두면 한 곳만 고쳐지는 실수가 난다(V16.8).
    private func panelSize(for model: DockModel) -> NSSize {
        if model.isCollapsed {
            return NSSize(width: DockBarLayout.handleWidth, height: DockBarLayout.handleHeight)
        }
        return ScreenGeometry.dockBarSize(
            linkCount: model.resolution.allItems.count,
            detailsVisible: model.isDetailsVisible,
            barHeight: model.effectiveAppearance.size.barHeight
        )
    }

    private func makePanel(model: DockModel) -> NSPanel {
        let size = panelSize(for: model)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // 테두리 없는 패널: 제목 표시줄이 없어 **프레임 크기 == 내용 크기**가 된다.
            // 제목 표시줄이 있으면 창 높이가 19pt 어긋나(요청 76 / 실제 95) 레이아웃이 일어날 때마다
            // 크기 변경이 반복되고 바가 밀려 내려간다(V14 사용자 보고에서 확인).
            // 창 이동은 본문의 드래그 영역(`WindowDragHandle`)이 담당한다.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = options.isFake ? "[FAKE] PaneDock" : "PaneDock"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 색상 모드는 **창을 만들 때도** 적용한다(레이아웃이 일어나야 적용되면 시작 화면이 시스템 색으로 남는다).
        panel.appearance = Self.panelAppearance(for: model.effectiveAppearance.colorMode)
        // 최소 크기는 **가장 작은 외형**을 기준으로 한다(작게 모드가 클램프되지 않게).
        panel.minSize = NSSize(
            width: DockBarLayout.minimumBarWidth,
            height: DockSizeSetting.small.barHeight
        )
        // 배경 드래그를 끈다. 바의 전용 드래그 영역만 창을 옮긴다(버튼과 충돌하지 않는다).
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: DockView(model: model))

        // 마우스가 Dock·호출 손잡이를 떠난 것을 **우리 창의 추적 영역**으로 안다.
        // 전역 마우스 감시도, 화면 읽기도 쓰지 않는다(입력 포커스도 건드리지 않는다).
        panel.contentView?.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )

        // 저장된 위치가 있으면 그대로 쓰고, 없으면 화면 하단이 기본이다.
        let saved = settings?.settings.windowOrigin
        let origin = ScreenGeometry.resolve(
            origin: saved.map { CGPoint(x: $0.x, y: $0.y) },
            size: panel.frame.size
        )
        panel.setFrameOrigin(origin)
        return panel
    }

    /// 지금 내용에 맞춰 창 크기를 맞춘다.
    ///
    /// 좌하단 좌표를 유지하므로 **바는 제자리에 있고 상세 보기가 위로 펼쳐진다.**
    /// 크기가 바뀌어 화면 밖으로 나가면 보이는 영역으로 보정한다(저장 위치는 건드리지 않는다).
    private func applyPanelSize() {
        guard let panel, let model else { return }
        let size = panelSize(for: model)
        // 색상 모드는 패널 외형으로 적용한다(SwiftUI 선호 색상보다 확실하다).
        panel.appearance = Self.panelAppearance(for: model.effectiveAppearance.colorMode)
        // 테두리 없는 패널이라 프레임 크기 == 내용 크기다. 그래도 읽는 값은 프레임 하나로 통일한다.
        let current = panel.frame.size
        // 창 크기를 바꾼 이유와 결과를 남긴다(위치가 밀리는 문제를 눈이 아니라 로그로 본다).
        model.appendEvent(
            "layout want=\(Int(size.width))x\(Int(size.height)) "
                + "frame=\(Int(current.width))x\(Int(current.height)) "
                + "origin=(\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))) "
                + "details=\(model.isDetailsVisible) "
                + "panelAppearance=\(panel.appearance?.name.rawValue ?? "nil")"
        )
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else {
            model.appendEvent("layout result=unchanged")
            return
        }
        isApplyingLayout = true
        lastProgrammaticLayout = Date()
        // 하단(좌하단 좌표)을 고정한다. 상세 보기는 위로 펼쳐진다.
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.setFrameOrigin(origin)
        model.appendEvent(
            "layout result=resized frame=\(Int(panel.frame.width))x\(Int(panel.frame.height)) "
                + "origin=(\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y)))"
        )
        isApplyingLayout = false
        // 펼침/접힘 자체도 레이아웃 변경이므로, 여기서 조건을 다시 보되 이미 접혀 있으면 그대로 둔다.
        scheduleCollapseCheck()
    }

    // MARK: - Dock 편집창

    /// 편집창을 띄운다. **추적 대상·잠금 상태를 건드리지 않는다.**
    @MainActor
    private func openEditor() {
        guard let model else { return }
        if editorWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = options.isFake ? "[FAKE] Dock 편집" : "Dock 편집"
            window.isReleasedWhenClosed = false
            // 창의 닫기 버튼·Cmd+W로 닫아도 **취소와 같게** 처리한다(저장하지 않은 모양·초안이 남지 않게).
            window.delegate = self
            window.contentView = NSHostingView(rootView: ItemEditorView(model: model))
            window.center()
            editorWindow = window
        }
        model.beginEditing()
        editorWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 색상 모드 → 패널 외형.
    static func panelAppearance(for mode: DockColorMode) -> NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 편집창을 닫는다(저장 성공·취소). **추적 대상·잠금 상태는 건드리지 않는다.**
    @MainActor
    private func closeEditor() {
        // 닫을 때 미리보기 외형을 버린다(저장하지 않은 모양은 남지 않는다).
        model?.discardAppearancePreview()
        editorWindow?.close()
    }

    /// 초안을 저장한다. **사용자가 저장을 눌렀을 때만** 파일에 쓴다.
    ///
    /// - 성공하면 기존 재로딩 경로(`applyCatalog`)로 즉시 반영한다(선택 취소 포함).
    /// - 충돌·거부·실패에는 파일을 건드리지 않고 안내문만 돌려준다.
    @MainActor
    private func saveDraft(_ catalog: ProjectCatalog, model: DockModel) -> (message: String, succeeded: Bool) {
        guard let store = catalogStore else {
            return (message: "저장할 수 없습니다: 프로젝트 설정을 사용할 수 없습니다", succeeded: false)
        }
        let outcome = store.save(catalog)
        switch outcome {
        case .saved(let backupPath):
            applyCatalog(to: model, from: store, isReload: true)
            if let backupPath {
                let name = (backupPath as NSString).lastPathComponent
                return (message: "저장했습니다. 원본을 백업했습니다: \(name)", succeeded: true)
            }
            return (message: "저장했습니다.", succeeded: true)
        case .conflict(let detail):
            return (
                message: "\(detail)\n'다시 시도'하면 지금 초안이 저장됩니다(바깥 변경을 덮어씁니다). "
                    + "바깥 변경을 살리려면 취소하고 '프로젝트 설정 다시 읽기' 후 다시 편집해 주세요.",
                succeeded: false
            )
        case .refused(let reason), .failed(let reason):
            return (message: "저장하지 못했습니다: \(reason)", succeeded: false)
        }
    }

    /// 위치 저장. 드래그 중에는 매번 쓰지 않고 잠깐 멈췄을 때 한 번만 쓴다.
    func windowDidMove(_ notification: Notification) {
        // **내가 크기를 맞추느라 옮긴 것은 사용자의 위치가 아니다.** 이것을 저장하면
        // 레이아웃이 일어날 때마다 위치가 조금씩 밀려 내려간다(V14 사용자 보고).
        if isApplyingLayout { return }
        if let last = lastProgrammaticLayout, Date().timeIntervalSince(last) < 0.75 { return }
        guard let panel, let settings, settings.canWrite else { return }
        let origin = panel.frame.origin
        pendingPositionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settings?.update {
                $0.windowOrigin = StoredOrigin(x: Double(origin.x), y: Double(origin.y))
            }
        }
        pendingPositionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === editorWindow {
            // 저장하지 않은 초안·미리보기가 남아 있으면 취소로 정리한다(닫아도 저장되지 않는다).
            if model?.draft != nil || model?.previewAppearance != nil {
                model?.cancelEditing()
            }
            return
        }
        endInvocation()
    }

    // MARK: - 자동 접기

    /// 지금 상태에서 접기 판단을 다시 한다(마우스 이탈·상호작용 종료·레이아웃 변경에서 부른다).
    private func scheduleCollapseCheck(after delay: TimeInterval = DockCollapsePolicy.delay) {
        collapseWork?.cancel()
        let token = collapseScheduler.nextToken()
        let work = DispatchWorkItem { [weak self] in self?.collapseIfAllowed(token: token) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func collapseContext() -> DockCollapseContext {
        let frame = panel?.frame ?? .zero
        let inside = (panel?.isVisible ?? false) && frame.contains(NSEvent.mouseLocation)
        return DockCollapseContext(
            mode: model?.effectiveAppearance.displayMode ?? .alwaysVisible,
            isCollapsed: model?.isCollapsed ?? false,
            mouseInsideDock: inside,
            isMouseButtonDown: NSEvent.pressedMouseButtons != 0,
            isInvoked: model?.isKeyboardSessionActive ?? false,
            isDetailsVisible: model?.isDetailsVisible ?? false,
            isEditorOpen: editorWindow?.isVisible ?? false,
            isModalOpen: NSApplication.shared.modalWindow != nil,
            isUserHidden: isUserHidden
        )
    }

    private func collapseIfAllowed(token: Int) {
        guard collapseScheduler.isCurrent(token) else {
            // 늦게 도착한 예약. 새로 펼친 Dock을 접지 않는다.
            model?.appendEvent("collapse result=stale")
            return
        }
        guard let model else { return }
        if let block = DockCollapsePolicy.collapseBlock(collapseContext()) {
            model.appendEvent("collapse result=blocked reason=\(block)")
            // 마우스를 누르고 있는 동안만 잠시 뒤 다시 본다(놓으면 접힌다).
            if DockCollapsePolicy.needsRecheckAfterBlock(block) { scheduleCollapseCheck(after: 0.5) }
            return
        }
        model.appendEvent("collapse result=collapsing")
        model.setCollapsed(true)
    }

    /// 마우스가 들어왔다(호출 손잡이 포함). **포커스를 빼앗지 않고** 펼치기만 한다.
    @objc func mouseEntered(with event: NSEvent) {
        model?.appendEvent("mouse=entered")
        collapseWork?.cancel()
        collapseScheduler.cancel()
        guard let model else { return }
        guard DockCollapsePolicy.shouldExpandForHover(collapseContext()) else { return }
        model.appendEvent("expand source=hover")
        model.setCollapsed(false)
    }

    /// 마우스가 떠났다. **바로 접지 않고** 잠시 뒤 조건을 다시 본다.
    @objc func mouseExited(with event: NSEvent) {
        model?.appendEvent("mouse=exited")
        scheduleCollapseCheck()
    }

    // MARK: - 호출/숨김

    /// 사용자가 명시적으로 호출했다. 이때만 활성화하고 키보드 포커스를 준다.
    private func showPanel() {
        guard let panel else { return }
        // 명시적 호출은 **숨김을 풀고 펼친다**(접힌 상태에서도 기존 키보드 조작을 쓸 수 있게).
        isUserHidden = false
        model?.setCollapsed(false)
        // 숨겨진 동안 내용이 바뀌었을 수 있다. 크기를 먼저 맞춘다.
        applyPanelSize()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model?.setDockInvoked(true)
        installKeyMonitor()
    }

    private func hidePanel() {
        // 사용자가 명시적으로 숨긴 것이다. 타이머·프로젝트 전환으로 다시 띄우지 않는다.
        isUserHidden = true
        endInvocation()
        panel?.orderOut(nil)
        // 여기서 Ghostty를 활성화하지 않는다. 사용자가 다른 앱으로 간 의도를 덮어쓰지 않는다.
    }

    private func endInvocation() {
        removeKeyMonitor()
        model?.setDockInvoked(false)
        // 호출 세션이 끝났으니 접기 조건을 다시 본다.
        scheduleCollapseCheck()
    }

    /// 다른 앱으로 이동하면 키보드 호출 세션을 해제한다(그 앱을 앞으로 가져오지는 않는다).
    func applicationDidResignActive(_ notification: Notification) {
        guard model?.isKeyboardSessionActive == true else { return }
        endInvocation()
    }

    private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible && model?.focusedItem != nil {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - 키보드

    /// 우리 앱으로 들어온 키 입력만 본다(로컬 모니터). 전역 감시가 아니고 권한도 필요 없다.
    /// 호출한 동안에만 설치하고, 닫으면 즉시 제거한다.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// true면 이벤트를 소비한다.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc — 상세 보기가 열려 있으면 그것부터 닫는다
            if model?.isDetailsVisible == true {
                model?.hideDetails()
                return true
            }
            hidePanel()
            return true
        case 48: // tab / shift-tab
            model?.moveFocus(forward: !event.modifierFlags.contains(.shift))
            return true
        case 36, 76, 49: // return / enter / space
            model?.activateFocusedItem()
            return true
        default:
            return false
        }
    }

    // MARK: - 전역 단축키

    private func installHotKey(model _: DockModel) {
        let hotKey = GlobalHotKey { [weak self] in
            self?.showPanel()
        }
        self.hotKey = hotKey
        applyHotKeyChoice()
    }

    private func applyHotKeyChoice() {
        guard let settings else { return }
        let choice = settings.settings.hotKeyEnabled ? settings.settings.hotKey : .disabled
        hotKeyRegistration = hotKey?.register(choice) ?? .failed(code: -1)
        rebuildStatusMenu()
    }

    // MARK: - 메뉴 막대

    /// 창을 숨긴 뒤 다시 표시할 수단. 앱이 `.accessory`라 Dock 아이콘이 없어서 필요하다.
    private func installStatusItem(model _: DockModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = options.isFake ? "PaneDock [FAKE]" : "PaneDock"
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        add(to: menu, title: "Dock 호출/닫기", action: #selector(togglePanelAction), key: "")
        add(to: menu, title: "잠금/해제", action: #selector(toggleLockAction), key: "")
        add(to: menu, title: "창 위치 초기화", action: #selector(resetPositionAction), key: "")
        add(to: menu, title: "프로젝트 설정 다시 읽기", action: #selector(reloadCatalogAction), key: "")
        add(to: menu, title: "Dock 편집…", action: #selector(openEditorAction), key: "")
        menu.addItem(.separator())

        let hotKeyItem = NSMenuItem(title: "호출 단축키", action: nil, keyEquivalent: "")
        let hotKeyMenu = NSMenu()
        let activeChoice = (settings?.settings.hotKeyEnabled ?? true)
            ? (settings?.settings.hotKey ?? .controlOptionCommandD)
            : .disabled
        for choice in HotKeyChoice.allCases {
            let entry = NSMenuItem(title: choice.displayName, action: #selector(selectHotKeyAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = (choice == activeChoice) ? .on : .off
            hotKeyMenu.addItem(entry)
        }
        hotKeyMenu.addItem(.separator())
        let status = NSMenuItem(
            title: "상태: \(hotKeyRegistration.message)",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        hotKeyMenu.addItem(status)
        hotKeyItem.submenu = hotKeyMenu
        menu.addItem(hotKeyItem)
        menu.addItem(.separator())

        add(to: menu, title: "PaneDock 종료", action: #selector(quitAction), key: "q")
        statusItem.menu = menu
    }

    private func add(to menu: NSMenu, title: String, action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @MainActor @objc private func togglePanelAction() {
        togglePanel()
    }

    @MainActor @objc private func toggleLockAction() {
        model?.toggleLock()
    }

    @MainActor @objc private func resetPositionAction() {
        settings?.resetWindowOrigin()
        guard let panel else { return }
        panel.setFrameOrigin(ScreenGeometry.resolve(origin: nil, size: panel.frame.size))
    }

    @MainActor @objc private func selectHotKeyAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = HotKeyChoice(rawValue: raw) else { return }
        settings?.update {
            $0.hotKey = choice
            $0.hotKeyEnabled = (choice != .disabled)
        }
        applyHotKeyChoice()
    }

    @MainActor @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
