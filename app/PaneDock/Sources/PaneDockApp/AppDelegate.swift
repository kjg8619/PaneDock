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
        // 진단용: 편집 초안에 항목을 추가하고 **저장까지** 해 본다(임시 카탈로그 전용).
        if let delay = options.editorSelfTestAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                guard let self, let model = self.model else { return }
                model.beginEditing(scope: .common)
                model.editorBeginAdd(kind: .folder)
                model.editorUpdateForm(name: "스크래치", target: "/tmp")
                model.editorCommitForm()
                model.saveDraft()
                model.appendEvent("editor-selftest done")
            }
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

    private func makePanel(model: DockModel) -> NSPanel {
        let size = ScreenGeometry.dockBarSize(
            linkCount: model.resolution.allItems.count,
            detailsVisible: model.isDetailsVisible
        )
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
        panel.minSize = NSSize(
            width: DockBarLayout.minimumBarWidth,
            height: DockBarLayout.barHeight
        )
        // 배경 드래그를 끈다. 바의 전용 드래그 영역만 창을 옮긴다(버튼과 충돌하지 않는다).
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: DockView(model: model))

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
        let size = ScreenGeometry.dockBarSize(
            linkCount: model.resolution.allItems.count,
            detailsVisible: model.isDetailsVisible
        )
        // 테두리 없는 패널이라 프레임 크기 == 내용 크기다. 그래도 읽는 값은 프레임 하나로 통일한다.
        let current = panel.frame.size
        // 창 크기를 바꾼 이유와 결과를 남긴다(위치가 밀리는 문제를 눈이 아니라 로그로 본다).
        model.appendEvent(
            "layout want=\(Int(size.width))x\(Int(size.height)) "
                + "frame=\(Int(current.width))x\(Int(current.height)) "
                + "origin=(\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))) "
                + "details=\(model.isDetailsVisible)"
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
            window.contentView = NSHostingView(rootView: ItemEditorView(model: model))
            window.center()
            editorWindow = window
        }
        model.beginEditing()
        editorWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
            return (message: "\(detail)\n메뉴에서 '프로젝트 설정 다시 읽기'를 한 뒤 다시 시도해 주세요.", succeeded: false)
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
        endInvocation()
    }

    // MARK: - 호출/숨김

    /// 사용자가 명시적으로 호출했다. 이때만 활성화하고 키보드 포커스를 준다.
    private func showPanel() {
        guard let panel else { return }
        // 숨겨진 동안 내용이 바뀌었을 수 있다. 크기를 먼저 맞춘다.
        applyPanelSize()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model?.setDockInvoked(true)
        installKeyMonitor()
    }

    private func hidePanel() {
        endInvocation()
        panel?.orderOut(nil)
        // 여기서 Ghostty를 활성화하지 않는다. 사용자가 다른 앱으로 간 의도를 덮어쓰지 않는다.
    }

    private func endInvocation() {
        removeKeyMonitor()
        model?.setDockInvoked(false)
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
