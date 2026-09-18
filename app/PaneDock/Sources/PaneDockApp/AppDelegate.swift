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
    /// 마우스가 Dock 위에 있는지 주기적으로 확인하는 타이머와 직전 값.
    private var presenceTimer: Timer?
    private var wasMouseInside: Bool?
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
    /// 사용 모드 전환(적용·복원·감지)을 한 곳에서 관리한다.
    private var dockModeController: DockModeController?
    /// 화면에 표시할 **실제 적용 상태**(선택값과 구분한다).
    private var dockAppliedState: DockAppliedState = .none
    /// 사용자가 자유롭게 둔 위치(설정에 저장되는 값). Custom의 **하단 가장자리 배치와 구분**한다.
    private var freeOrigin: CGPoint?
    /// 지금 하단 가장자리에 붙여 둔 상태인가(복귀 시 자유 좌표로 되돌린다).
    private var isBottomAnchored = false

    // MARK: - 사용 모드 (Mac Dock / Custom Dock)

    /// **컨트롤러만** 만든다. 저장된 모드 적용은 화면·메뉴가 준비된 뒤 `applySavedModeAtStartup`이 한다.
    ///
    /// 초기화 시점에는 창도 메뉴도 없으므로, 여기서 시스템 설정을 건드리면 "준비 전에 숨기지 않는다"는
    /// 규칙을 지킬 수 없다.
    private func installDockModeController(store: SettingsStore, model: DockModel) {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PaneDock", isDirectory: true)
        let isFake = options.isFake
        let recovery = DockRecoveryStore(url: isFake ? nil : support?.appendingPathComponent("dock-recovery.json"))
        let lock = DockModeLock(url: isFake ? nil : support?.appendingPathComponent("dock-mode.lock"))
        dockModeController = DockModeController(
            system: SystemDockControl(allowRestart: !options.noDockRestart) { [weak self] line in
                self?.model?.appendEvent(line)
            },
            recovery: recovery,
            lock: lock,
            log: { [weak self] line in self?.model?.appendEvent(line) }
        )
        model.appendEvent("dockmode controller=ready recovery=\(recovery.loadResult().summary)")
    }

    /// 저장된 모드·동의·복구 상태를 **결정 함수**로 판정하고 그대로 실행한다(창·메뉴 준비 뒤 호출).
    private func applySavedModeAtStartup(store: SettingsStore, model: DockModel) {
        guard let controller = dockModeController else { return }

        // 승인된 검증용 플래그(임시 설정 파일에서만 쓴다): 선택·동의·억제 승인을 파일에 반영한다.
        if let launchMode = options.dockModeAtLaunch {
            store.update { settings in
                settings.dockMode = launchMode
                if launchMode == .custom {
                    settings.customDockConsent = ISO8601DateFormatter().string(from: Date())
                    settings.dockSuppressionApproved = options.dockSuppressionApproved
                }
            }
            model.appendEvent("dockmode launch flag=\(launchMode.rawValue) suppression=\(options.dockSuppressionApproved)")
        }

        let decision = DockStartupPolicy.decide(
            selectedMode: store.settings.dockMode,
            consent: store.settings.customDockConsent,
            suppressionApproved: store.settings.dockSuppressionApproved,
            lastApplyFailedAt: store.settings.dockLastApplyFailedAt,
            recovery: controller.recoveryState()
        )
        model.appendEvent("dockmode startup decision=\(decisionName(decision)) reason=\(decision.reason)")

        switch decision {
        case .applyCustom(let suppression):
            do {
                let outcome = try controller.applyCustom(
                    consent: true,
                    suppressionApproved: suppression,
                    prepareScreen: { [weak self] in try self?.prepareCustomScreen() }
                )
                dockAppliedState = outcome.applied
                store.update { $0.dockLastApplyFailedAt = nil }
                model.appendEvent("dockmode startup apply=ok keys=\(outcome.changedKeys.count)")
            } catch let error as DockModeError {
                dockAppliedState = .none
                markApplyFailure(error)
                appendStartupNotice("Custom 모드를 적용하지 못했습니다: \(error.message)")
                model.appendEvent("dockmode startup apply=failed reason=\(error.message)")
            } catch {
                dockAppliedState = .none
            }
        case .recoverFirst(let reason):
            // 복구가 먼저다: 그 위에 새 적용을 겹치지 않는다. 복구는 사용자가 메뉴/명령으로 실행한다.
            dockAppliedState = .none
            appendStartupNotice("\(reason) — 메뉴 › 사용 모드 › ‘기본 Dock으로 복원’으로 먼저 정리해 주세요.")
            model.appendEvent("dockmode startup recovery-first reason=\(reason)")
        case .skipAfterFailure(let reason):
            dockAppliedState = .none
            appendStartupNotice("\(reason) 메뉴 › 사용 모드에서 직접 적용하거나 복원해 주세요.")
            model.appendEvent("dockmode startup apply=skipped reason=\(reason)")
        case .unsupported(let reason):
            dockAppliedState = .none
            appendStartupNotice(reason)
            model.appendEvent("dockmode startup unsupported reason=\(reason)")
        case .macDock(let reason):
            dockAppliedState = .none
            model.appendEvent("dockmode startup mac-dock reason=\(reason)")
        }
    }

    private func decisionName(_ decision: DockStartupDecision) -> String {
        switch decision {
        case .macDock: return "macDock"
        case .applyCustom: return "applyCustom"
        case .recoverFirst: return "recoverFirst"
        case .skipAfterFailure: return "skipAfterFailure"
        case .unsupported: return "unsupported"
        }
    }

    /// 시작 안내 문구를 덧붙인다(설정 안내와 같은 자리에 보인다).
    private func appendStartupNotice(_ text: String) {
        startupNotice = startupNotice.isEmpty ? text : startupNotice + "\n" + text
        model?.setSettingsNotice(startupNotice.isEmpty ? nil : startupNotice)
    }

    /// 커스텀 화면 준비. **준비가 끝난 것을 확인하고 돌아와야** 코어가 시스템 설정을 쓴다.
    ///
    /// - 크기가 같아도 하단 배치·표시를 **다시 적용**한다.
    /// - 확인 전에는 기본 Dock을 숨기지 않는다(실패하면 적용 전체가 되돌아간다).
    private func prepareCustomScreen() throws {
        guard let panel, let model else {
            throw DockScreenError.notReady("창이 아직 만들어지지 않았습니다")
        }
        // 1) 접힘을 풀고 내용에 맞는 크기를 맞춘다.
        model.setCollapsed(false)
        applyPanelSize()
        // 2) 하단 가장자리 배치를 **강제로** 적용한다(이미 그 자리여도 다시 확인한다).
        _ = anchorToBottom(panel: panel, force: true)
        // 3) 창을 올린다(활성화는 하지 않는다 — 다른 앱의 포커스를 빼앗지 않는다).
        panel.orderFrontRegardless()

        // 4) 실제로 준비됐는지 확인한다(짧게 기다린다). 창 서버가 아직 반영하지 않았을 수 있다.
        var ready = false
        for _ in 0..<25 {
            if panel.isVisible, isAtBottomEdge(panel) { ready = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        model.appendEvent(
            "dockmode prepare=ready:\(ready) visible=\(panel.isVisible) "
                + "origin=(\(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))) "
                + "screenBottom=\(Int(ScreenGeometry.bottomAnchorOrigin(for: panel.frame.size, panelFrame: panel.frame).y))"
        )
        guard ready else {
            throw DockScreenError.notReady("패널이 하단에 보이지 않습니다")
        }
    }

    private func isAtBottomEdge(_ panel: NSPanel) -> Bool {
        let expected = ScreenGeometry.bottomAnchorOrigin(for: panel.frame.size, panelFrame: panel.frame)
        return abs(panel.frame.origin.y - expected.y) <= 1.0
    }

    /// 모드 선택(선택만으로는 아무것도 바꾸지 않는다).
    @MainActor @objc private func selectDockModeAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DockMode(rawValue: raw) else { return }
        guard mode.isImplemented else {
            model?.appendEvent("dockmode select=\(mode.rawValue) result=unsupported")
            return
        }
        settings?.update { $0.dockMode = mode }
        model?.appendEvent("dockmode select=\(mode.rawValue) applied=\(dockAppliedState.isCustom ? "custom" : "none")")
        rebuildStatusMenu()
    }

    /// 적용 — 사용자가 명시적으로 눌렀을 때만 시스템 설정을 바꾼다.
    @MainActor @objc private func applyDockModeAction() {
        guard let model, let controller = dockModeController, let store = settings else { return }
        guard (store.settings.dockMode ?? .macDock) != .macDock else {
            model.appendEvent("dockmode apply result=skipped selected=macDock")
            return
        }
        // 첫 적용에는 변경 항목·복원 방법을 설명하고 동의를 받는다.
        // 재등장 억제(문서화되지 않은 설정)는 **같은 대화상자에서 별도로** 승인받는다.
        let needsConsent = store.settings.customDockConsent == nil
        var suppression = store.settings.dockSuppressionApproved
        if needsConsent {
            guard let decision = confirmCustomDockConsent(suppressionSelected: suppression) else {
                model.appendEvent("dockmode apply result=declined")
                return
            }
            suppression = decision
        }
        do {
            let outcome = try controller.applyCustom(
                consent: true,
                suppressionApproved: suppression,
                prepareScreen: { [weak self] in try self?.prepareCustomScreen() }
            )
            dockAppliedState = outcome.applied
            // 동의는 **실제로 적용된 뒤에** 기록한다(실패한 시도로 동의를 남기지 않는다).
            store.update { settings in
                if settings.customDockConsent == nil {
                    settings.customDockConsent = ISO8601DateFormatter().string(from: Date())
                }
                settings.dockSuppressionApproved = suppression
            }
            store.update { $0.dockLastApplyFailedAt = nil }
            var message = "Custom Dock을 적용했습니다 — 바꾼 설정 \(outcome.changedKeys.count)개(종료·해제 시 복원)"
            if outcome.changedKeys.isEmpty {
                message = "이미 원하는 상태였습니다 — 바꾼 설정 없음(기본 Dock을 숨긴 상태로 씁니다)"
            }
            if let lockNote = outcome.lockNote { message += "\n" + lockNote }
            if !outcome.notes.isEmpty { message += "\n" + outcome.notes.joined(separator: "\n") }
            model.setActionMessage(message)
            model.appendEvent("dockmode apply result=ok keys=\(outcome.changedKeys.joined(separator: ",")) suppressed=\(suppression) lock=\(outcome.lockNote ?? "-")")
        } catch let error as DockModeError {
            dockAppliedState = .none
            markApplyFailure(error)
            model.setActionMessage(error.message)
            model.appendEvent("dockmode apply result=failed reason=\(error.message)")
        } catch {
            dockAppliedState = .none
        }
        applyPanelSize()
        rebuildStatusMenu()
    }

    /// 시스템 단계에서 적용이 실패했음을 남긴다(다음 실행에서 자동 적용하지 않게).
    private func markApplyFailure(_ error: DockModeError) {
        switch error {
        case .applyFailed, .rollbackFailed:
            settings?.update { $0.dockLastApplyFailedAt = ISO8601DateFormatter().string(from: Date()) }
        default:
            break
        }
    }

    /// 복원 — 모드 해제·정상 종료·미복원 복구가 **같은 경로**를 쓴다.
    ///
    /// 결과 종류(완전/부분/실패/되돌릴 것 없음)를 그대로 돌려준다. 성공으로 뭉개지 않는다.
    @discardableResult
    private func restoreSystemDock(reason: String) -> DockRestoreOutcome? {
        guard let controller = dockModeController else { return nil }
        do {
            let outcome = try controller.restoreToMacDock()
            dockAppliedState = .none
            model?.appendEvent(
                "dockmode restore reason=\(reason) kind=\(outcome.kind.rawValue) "
                    + "restored=\(outcome.count(.restored)) already=\(outcome.count(.alreadyOriginal)) "
                    + "userChanged=\(outcome.count(.userChanged)) removed=\(outcome.count(.keyRemoved)) "
                    + "failed=\(outcome.count(.failed)) left=\(outcome.recordLeft) restart=\(outcome.restartPerformed)"
            )
            if !outcome.notes.isEmpty {
                model?.appendEvent("dockmode restore notes=\(outcome.notes.joined(separator: " | "))")
            }
            // Custom에서 나왔으니 **커스텀 패널과 입력 세션을 정리**한다.
            endCustomSession(reason: reason)
            return outcome
        } catch let error as DockModeError {
            dockAppliedState = .none
            model?.setActionMessage(error.message)
            model?.appendEvent("dockmode restore reason=\(reason) result=failed reason=\(error.message)")
            endCustomSession(reason: reason)
            return nil
        } catch {
            model?.appendEvent("dockmode restore reason=\(reason) result=failed")
            endCustomSession(reason: reason)
            return nil
        }
    }

    /// Custom 화면과 키보드 호출 세션을 정리하고 자유 좌표로 되돌린다.
    private func endCustomSession(reason: String) {
        guard let panel else { return }
        endInvocation()                 // 키 모니터 해제 + 키보드 선택 해제
        restoreFreePlacement(panel: panel)
        panel.orderOut(nil)
        // 모드 때문에 숨긴 것이지 사용자가 숨긴 것이 아니다(Custom에 다시 들어가면 보여야 한다).
        isUserHidden = false
        model?.appendEvent("dockmode session=ended reason=\(reason)")
    }

    /// 사용자가 바꾼 항목을 **명시적으로** 기록에서 정리한다(시스템 값은 그대로 둔다).
    @MainActor @objc private func forgetUserChangedAction() {
        guard let controller = dockModeController else { return }
        guard let record = controller.recoveryState().record else {
            model?.setActionMessage("정리할 기록이 없습니다.")
            rebuildStatusMenu()
            return
        }
        switch controller.forgetUserChanged(operationID: record.operationID) {
        case .written:
            model?.setActionMessage("사용자가 바꾼 항목을 기록에서 정리했습니다(시스템 값은 그대로).")
            model?.appendEvent("dockmode forget-user-changed result=ok")
        case .refusedPendingRestore(let keys):
            model?.setActionMessage("정리하지 못했습니다: \(keys.joined(separator: ","))")
        case .refusedUnreadable(let reason):
            model?.setActionMessage("정리하지 못했습니다: \(reason)")
        case .failed(let reason):
            model?.setActionMessage("정리하지 못했습니다: \(reason)")
        case .noPath:
            model?.setActionMessage("복구 기록 경로가 없습니다.")
        }
        rebuildStatusMenu()
    }

    @MainActor @objc private func restoreDockModeAction() {
        if let outcome = restoreSystemDock(reason: "menu") {
            var message = outcome.userMessage
            if !outcome.notes.isEmpty {
                message += "\n" + outcome.notes.joined(separator: "\n")
            }
            model?.setActionMessage(message)
        }
        applyPanelSize()
        rebuildStatusMenu()
    }

    /// 첫 Custom 적용 동의 대화상자 — **바꿀 항목과 복원 방법**을 먼저 설명한다.
    ///
    /// 재등장 억제는 문서화되지 않은 설정이므로 **체크박스로 따로** 승인받는다(기본 꺼짐).
    /// 반환: `nil` = 사용자가 취소했다(아무 것도 바꾸지 않는다). 그 밖에는 억제 승인 여부.
    private func confirmCustomDockConsent(suppressionSelected: Bool) -> Bool? {
        let alert = NSAlert()
        alert.messageText = "Custom Dock을 적용할까요?"
        alert.informativeText = [
            "PaneDock이 기본 macOS Dock을 숨기고 화면 하단을 씁니다.",
            "",
            "바꾸는 설정(원래 값을 기록한 뒤, 해제·종료 시 그대로 되돌립니다):",
            "• com.apple.dock autohide = true (기본 Dock 자동 숨김)",
            "• 설정 반영을 위해 Dock을 한 번 다시 시작합니다.",
            "• 원래 없던 키는 삭제하고, 실행 중 직접 바꾼 값은 덮어쓰지 않습니다.",
            "",
            "되돌리기: 메뉴 › 사용 모드 › ‘기본 Dock으로 복원’ (앱 종료 시에도 자동 복원)",
        ].joined(separator: "\n")

        // 별도 승인 항목: 하단 접근 시 재등장 억제(문서화되지 않은 설정).
        let checkbox = NSButton(checkboxWithTitle: "하단에 닿아도 Dock이 다시 나오지 않게 한다 (문서화되지 않은 설정)", target: nil, action: nil)
        checkbox.state = suppressionSelected ? .on : .off
        checkbox.font = .systemFont(ofSize: 11)
        let note = NSTextField(wrappingLabelWithString: "• autohide-delay·autohide-time-modifier 값을 바꿉니다. 되돌리면 삭제합니다.\n• 체크하지 않으면 자동 숨김만 적용되며, 하단에 닿으면 Dock이 다시 나타날 수 있습니다.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [checkbox, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 56)
        alert.accessoryView = stack

        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return checkbox.state == .on
    }

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
        // 배치 저장: 같은 규칙으로 설정 파일에만 쓴다(projects.json은 건드리지 않는다).
        // 값이 같으면 `SettingsStore`가 파일을 쓰지 않는다(바뀐 파일만 저장).
        model.onSaveLayout = { [weak self] layout in
            guard let self, let settings = self.settings else {
                return (message: "저장할 수 없습니다: 설정 저장소를 열지 못했습니다", succeeded: false)
            }
            if let reason = settings.writeBlockedReason {
                return (message: "배치를 저장하지 않았습니다: \(reason)", succeeded: false)
            }
            guard settings.update({ $0.layout = layout }) else {
                return (message: "배치를 저장하지 못했습니다: 설정 파일에 쓰지 못했습니다", succeeded: false)
            }
            self.model?.applyLayout(layout)
            return (message: "배치를 저장했습니다.", succeeded: true)
        }
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
        installDockModeController(store: store, model: model)

        // 저장된 외형을 반영하고 시작한다(없던 설정이면 기본 외형).
        model.applyAppearance(store.settings.appearance)
        // 저장된 구성형 배치(순서·프로젝트 영역 너비·카드)도 함께 반영한다.
        model.applyLayout(store.settings.layout)
        // 진단용: 완료(00:00) 상태를 확인하기 위해 타이머 기본 시간을 바꾼다(제품 기본값은 25분).
        if let seconds = options.timerSecondsOverride {
            model.setTimerDuration(seconds)
        }
        // 진단용: 키보드 경로(초점 이동 → 활성화)를 순서대로 실행한다.
        if let delay = options.keyboardSelfTestAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                self?.model?.runKeyboardSelfTest()
            }
        }
        // 진단용: 입력 없이 첫 집중 타이머를 시작한다(완료 상태까지 화면으로 관측).
        if let delay = options.timerAutostartAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                guard let self, let model = self.model else { return }
                guard let card = model.effectiveLayout.cards.first(where: { $0.kind == .focusTimer }) else { return }
                model.performTimer(.start, cardID: card.id, source: .menu)
                model.appendEvent("timer-selftest start card=\(card.id)")
            }
        }
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
        startPresenceTimer()
        installStatusItem(model: model)
        installHotKey(model: model)
        model.start(intervalMilliseconds: options.intervalMilliseconds)

        // **창·메뉴가 준비된 뒤**에 저장된 모드를 적용한다(준비 전에 시스템 설정을 쓰지 않는다).
        // 준비 완료를 로그로 남긴다 — 순서를 눈이 아니라 기록으로 확인할 수 있게.
        model.appendEvent(
            "dockmode ready panel=built(\(panel.frame.width)x\(panel.frame.height)) "
                + "menu=\(statusItem != nil ? "installed" : "missing")"
        )
        applySavedModeAtStartup(store: store, model: model)
        rebuildStatusMenu()

        if options.hidden {
            panel.orderOut(nil)
        } else if dockAppliedState.isCustom || options.previewCustom {
            // Custom 모드: 하단 주 Dock으로 보여준다(활성화는 하지 않는다).
            panel.orderFrontRegardless()
            if options.previewCustom, !dockAppliedState.isCustom {
                // 미리보기는 **적용이 아니다**: 시스템 Dock 설정은 그대로다.
                // 다만 준비 경로(접힘 해제·하단 배치·표시·확인)는 **실제와 같은 함수**를 지나간다.
                do {
                    try prepareCustomScreen()
                    model.setActionMessage("미리보기 — Custom은 아직 적용되지 않았습니다(기본 Dock 설정 그대로).")
                } catch {
                    model.setActionMessage("미리보기 준비 실패: \(error)")
                }
                model.appendEvent("panel preview mode=custom applied=none")
            }
        } else {
            // Mac Dock 모드(또는 선택 안 함): 기본 Dock을 그대로 두고 **커스텀 화면을 띄우지 않는다**.
            panel.orderOut(nil)
            model.appendEvent("panel hidden mode=macDock (메뉴 › 사용 모드에서 Custom 선택·적용)")
        }

        persistCorrectedOriginIfNeeded()
        logStartup()

        // 진단용 창 이동. 사용자가 헤더를 드래그한 것과 같은 저장 경로(windowDidMove)를 탄다.
        if let target = options.moveTo, options.moveAfterMilliseconds == nil {
            panel.setFrameOrigin(target)
        }
        if let target = options.moveTo, let delay = options.moveAfterMilliseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000.0) { [weak self] in
                self?.panel?.setFrameOrigin(target)
            }
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
        // Custom(과 미리보기)에서는 창이 **하단 가장자리에 붙어 있다.** 그 자리를 저장하면
        // 사용자가 두었던 자유 좌표를 잃는다 — 저장하지 않는다.
        if dockAppliedState.isCustom || options.previewCustom {
            model?.appendEvent("dockmode corrected-origin skipped (하단 기준)")
            return
        }
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
        let line = "PaneDock startup: build=[\(model?.build.logText ?? "-")] mode=\(mode) adapter=\(options.hostSource.rawValue) settings=\(outcome) file=\(file) "
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

    /// 정상 종료는 **모드 해제와 같은 복원 경로**를 쓴다.
    func applicationWillTerminate(_ notification: Notification) {
        // **우리가 적용한 Custom 세션만** 정상 종료에서 되돌린다.
        // 기록이 남아 있어도 다른 인스턴스가 쓰는 세션이면 건드리지 않는다(그 인스턴스의 소유다).
        guard dockAppliedState.isCustom else {
            if let state = dockModeController?.recoveryState(), state.record != nil {
                model?.appendEvent("dockmode quit-restore skipped (다른 인스턴스 세션일 수 있음)")
            }
            return
        }
        if let outcome = restoreSystemDock(reason: "quit") {
            // 복원 자체는 restoreSystemDock이 로그에 남긴다(여기서는 결과만 한 줄 덧붙인다).
            model?.appendEvent(
                "dockmode quit-restore kind=\(outcome.kind.rawValue) left=\(outcome.recordLeft)"
            )
        }
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
        // 구성형 화면: **화면에 그리는 표시 목록과 같은 계산**이 바 폭을 정한다.
        // 항목 수로 다시 계산하지 않으므로 프로젝트가 바뀌어도 창이 흔들리지 않는다.
        return NSSize(
            width: model.display.barWidth,
            height: DockBarLayout.windowHeight(
                detailsVisible: model.isDetailsVisible,
                barHeight: model.effectiveAppearance.size.barHeight
            )
        )
    }

    /// 커스텀 화면 준비가 실제로 끝나지 않았을 때(코어가 시스템 설정을 쓰지 않게 한다).
    enum DockScreenError: Error {
        case notReady(String)

        var message: String {
            switch self {
            case .notReady(let reason): return "커스텀 화면이 준비되지 않았습니다: \(reason)"
            }
        }
    }

    /// Custom 모드에서 창을 **하단 가장자리**에 붙인다.
    ///
    /// 자유 좌표(사용자가 옮긴 위치)는 `freeOrigin`에 그대로 두고 **덮어쓰지 않는다.**
    /// `force`는 "이미 그 자리여도 다시 적용"이다 — 크기가 같아도 진입 시 배치를 확정하기 위해 쓴다.
    @discardableResult
    private func anchorToBottom(panel: NSPanel, force: Bool = false) -> Bool {
        // 적용 중이거나 미리보기일 때, 또는 준비 단계에서 강제로(진입 시).
        guard dockAppliedState.isCustom || options.previewCustom || force else { return false }
        let size = panel.frame.size
        // **대상 화면의 실제 아래 가장자리** 기준(기본 Dock 영역을 제외한 visibleFrame이 아니다).
        let origin = ScreenGeometry.bottomAnchorOrigin(for: size, panelFrame: panel.frame)
        let sameSpot = abs(panel.frame.origin.y - origin.y) <= 0.5 && abs(panel.frame.origin.x - origin.x) <= 0.5
        if !sameSpot {
            isApplyingLayout = true
            lastProgrammaticLayout = Date()
            panel.setFrameOrigin(origin)
            isApplyingLayout = false
        }
        isBottomAnchored = true
        model?.appendEvent(
            "dockmode anchor=bottom origin=(\(Int(origin.x)),\(Int(origin.y))) "
                + "moved=\(!sameSpot) freeOrigin=\(freeOrigin.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-")"
        )
        return true
    }

    /// Mac Dock으로 돌아갈 때 **자유 좌표**로 되돌린다(가장자리 배치와 분리되어 있다).
    private func restoreFreePlacement(panel: NSPanel) {
        guard isBottomAnchored else { return }
        let origin = ScreenGeometry.resolve(origin: freeOrigin, size: panel.frame.size)
        isApplyingLayout = true
        lastProgrammaticLayout = Date()
        panel.setFrameOrigin(origin)
        isApplyingLayout = false
        isBottomAnchored = false
        model?.appendEvent("dockmode anchor=none origin=(\(Int(origin.x)),\(Int(origin.y))) (자유 좌표 복귀)")
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
        // 명시적 호출에서 키보드 조작(Tab/Enter/Esc)을 받으려면 **키 윈도가 되어야 한다**.
        // hover로 펼치는 경로는 makeKey를 부르지 않으므로 입력 포커스를 빼앗지 않는다.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 색상 모드는 **창을 만들 때도** 적용한다(레이아웃이 일어나야 적용되면 시작 화면이 시스템 색으로 남는다).
        panel.appearance = Self.panelAppearance(for: model.effectiveAppearance.colorMode)
        // 최소 크기는 **가장 작은 상태(호출 손잡이)** 를 기준으로 한다.
        // 자동 접기가 최소 크기 제한에 막히지 않게 하고, 작게 모드도 클램프되지 않게 한다.
        panel.minSize = NSSize(
            width: DockBarLayout.handleWidth,
            height: DockBarLayout.handleHeight
        )
        // 배경 드래그를 끈다. 바의 전용 드래그 영역만 창을 옮긴다(버튼과 충돌하지 않는다).
        panel.isMovableByWindowBackground = false
        let hosting = NSHostingView(rootView: DockView(model: model))
        // **창 크기는 모델이 계산한 값이 정한다.** SwiftUI 내용의 고유 크기가 창을 끌고 가면
        // 화면에 그린 폭과 창 폭이 어긋난다(V18.5에서 1079pt로 벌어진 것을 로그로 확인).
        hosting.sizingOptions = []
        panel.contentView = hosting

        // 저장된 위치가 있으면 그대로 쓰고, 없으면 화면 하단이 기본이다.
        let saved = settings?.settings.windowOrigin
        let origin = ScreenGeometry.resolve(
            origin: saved.map { CGPoint(x: $0.x, y: $0.y) },
            size: size
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        // 자유 좌표를 기억해 둔다(Custom에서 하단에 붙여도 이 값은 그대로 남는다).
        freeOrigin = saved.map { CGPoint(x: $0.x, y: $0.y) }
        anchorToBottom(panel: panel)
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
        // Custom 모드에서는 크기·상세 보기·접기가 바뀌어도 **하단 기준 위치를 유지**한다.
        anchorToBottom(panel: panel)
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
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = options.isFake ? "[FAKE] Dock 편집" : "Dock 편집"
            window.isReleasedWhenClosed = false
            // 창의 닫기 버튼·Cmd+W로 닫아도 **취소와 같게** 처리한다(저장하지 않은 모양·초안이 남지 않게).
            window.delegate = self
            // 창 크기는 **창이** 정한다(내용이 커져도 저장·취소 푸터가 잘리지 않는다).
            let hosting = NSHostingView(rootView: ItemEditorView(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.minSize = NSSize(width: 860, height: 560)
            window.setContentSize(NSSize(width: 900, height: 760))
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
        // Custom(과 미리보기)에서는 **하단 가장자리 기준**이므로 끌어도 자유 좌표를 덮어쓰지 않는다.
        if dockAppliedState.isCustom || options.previewCustom {
            model?.appendEvent("dockmode drag ignored (Custom: 하단 기준)")
            anchorToBottom(panel: panel)
            return
        }
        let origin = panel.frame.origin
        freeOrigin = origin
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
            if model?.draft != nil || model?.previewAppearance != nil || model?.previewLayout != nil {
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

    /// 마우스가 Dock·호출 손잡이 위에 있는지 **0.2초마다 위치만** 본다.
    ///
    /// 추적 영역(`NSTrackingArea`)은 이 비활성 패널에서 enter/exit를 주지 않았다(값으로 확인).
    /// 전역 키 감시도, 화면 읽기도 아니다 — 우리 창 좌표와 마우스 위치만 비교한다.
    private func evaluateMousePresence() {
        guard let panel, let model, panel.isVisible else {
            wasMouseInside = nil   // 숨김/닫힘: 다음에 보일 때 다시 기준을 잡는다
            return
        }
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        defer { wasMouseInside = inside }
        guard let previous = wasMouseInside, previous != inside else { return }
        if inside {
            // 손잡이로 들어왔다. **포커스를 빼앗지 않고** 펼치기만 한다.
            collapseWork?.cancel()
            collapseScheduler.cancel()
            guard DockCollapsePolicy.shouldExpandForHover(collapseContext()) else { return }
            model.appendEvent("expand source=hover")
            model.setCollapsed(false)
        } else {
            model.appendEvent("mouse=exited")
            scheduleCollapseCheck()
        }
    }

    private func startPresenceTimer() {
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.evaluateMousePresence()
        }
    }

    // MARK: - 호출/숨김

    /// 사용자가 명시적으로 호출했다. 이때만 활성화하고 키보드 포커스를 준다.
    private func showPanel() {
        // 커스텀 화면은 **Custom이 적용된 동안에만** 보인다. 그 밖에는 띄우지 않고 메뉴로 안내한다.
        guard dockAppliedState.isCustom || options.previewCustom else {
            let selected = settings?.settings.dockMode
            model?.appendEvent("invoke blocked applied=none selected=\(selected?.rawValue ?? "none")")
            if selected == .custom {
                model?.setActionMessage("Custom 모드를 아직 적용하지 않았습니다 — 메뉴 › 사용 모드 › ‘Custom Dock 적용’.")
            } else {
                model?.setActionMessage("Mac Dock 모드입니다 — 메뉴 › 사용 모드에서 Custom Dock을 선택·적용하세요.")
            }
            // 상태 메뉴를 열어 설정·모드 전환으로 바로 갈 수 있게 한다.
            statusItem?.button?.performClick(nil)
            return
        }
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
            guard let self, self.panel?.isVisible == true, self.editorWindow?.isVisible != true else { return event }
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
        // 보조 메뉴가 떠 있는 동안에는 메뉴가 키를 받아야 한다(우리가 가로채면 Enter/Esc가 먹히지 않는다).
        if model?.isMenuTracking == true { return false }
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
        // 메뉴바는 **pane 형태의 단색 심볼**을 쓴다(A 시안). 가짜 모드는 흐리게 그려 구분한다.
        item.button?.image = PaneDockSymbol.menuBarImage(isActive: !options.isFake)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = options.isFake
            ? "PaneDock — 가짜 데이터 모드(실제 터미널에 연결되지 않았습니다)"
            : "PaneDock — ⌃⌥⌘D로 Dock을 부릅니다"
        item.button?.setAccessibilityLabel("PaneDock")
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        add(to: menu, title: "Dock 호출/닫기", action: #selector(togglePanelAction), key: "")
        modeSubmenu(into: menu)
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

    /// 사용 모드 하위 메뉴 — **선택값과 실제 적용 상태를 구분해** 보여준다.
    private func modeSubmenu(into menu: NSMenu) {
        let selected = settings?.settings.dockMode
        let title = "사용 모드: \(selected?.label ?? "선택 안 함") · \(dockAppliedState.isCustom ? "적용됨" : "미적용")"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // 자동 활성화를 끈다: action이 있는 항목도 **적용 상태에 따라** 켜고 끈다
        // (Mac Dock을 고른 상태에서 '적용'이 눌리면 안 된다).
        submenu.autoenablesItems = false

        for mode in DockMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(selectDockModeAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = (mode == selected) ? .on : .off
            if !mode.isImplemented {
                // 미구현 모드는 **작동하는 선택지로 제공하지 않는다**.
                entry.isEnabled = false
                entry.title = "\(mode.label) — 미구현"
            }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        // 복구 기록 상태 — **Custom이 아니어도** 여기서 보이고 복원으로 갈 수 있다.
        let recovery = dockModeController?.recoveryState() ?? .noPath
        // 복원이 끝나지 않았으면 '적용 안 됨'이 아니라 **미완료**로 보여준다(정상 복귀와 구분).
        let pendingCount = recovery.record?.pendingKeyLabels.count ?? 0
        let statusTitle: String = {
            if dockAppliedState.isCustom { return "적용 상태: \(dockAppliedState.label)" }
            switch recovery {
            case .record(let record) where record.hasPendingWork:
                return "적용 상태: 복원 미완료(남은 항목 \(record.pendingKeyLabels.count))"
            case .unreadable:
                return "적용 상태: 복구 기록을 읽을 수 없음"
            case .none, .noPath, .record:
                return "적용 상태: \(dockAppliedState.label)"
            }
        }()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        if pendingCount > 0, !dockAppliedState.isCustom {
            // 다시 시도할 수 있다는 것을 메뉴에서 바로 보이게 한다.
            let retry = NSMenuItem(title: "복원 재시도 가능(남은 항목 \(pendingCount))", action: nil, keyEquivalent: "")
            retry.isEnabled = false
            submenu.addItem(retry)
        }
        let consent = NSMenuItem(
            title: settings?.settings.customDockConsent == nil ? "Custom 동의: 없음" : "Custom 동의: 있음",
            action: nil,
            keyEquivalent: ""
        )
        consent.isEnabled = false
        submenu.addItem(consent)

        let recoveryItem = NSMenuItem(title: "복구 기록: \(recovery.summary)", action: nil, keyEquivalent: "")
        recoveryItem.isEnabled = false
        submenu.addItem(recoveryItem)
        if let owner = dockModeController?.lockOwner(), owner.ownerPID != ProcessInfo.processInfo.processIdentifier {
            let lockItem = NSMenuItem(
                title: "다른 인스턴스 작업 중(pid=\(owner.ownerPID), \(owner.purpose))",
                action: nil,
                keyEquivalent: ""
            )
            lockItem.isEnabled = false
            submenu.addItem(lockItem)
        }

        submenu.addItem(.separator())
        // 되돌릴 것이 있으면(적용 중이거나 미복원 기록·손상 기록) 복원으로 갈 수 있어야 한다.
        let restorable: Bool = {
            if dockAppliedState.isCustom { return true }
            switch recovery {
            case .record, .unreadable: return true
            case .none, .noPath: return false
            }
        }()
        let apply = NSMenuItem(title: "Custom Dock 적용", action: #selector(applyDockModeAction), keyEquivalent: "")
        apply.target = self
        apply.isEnabled = (selected ?? .macDock) != .macDock && !dockAppliedState.isCustom && !restorable
        if restorable, (selected ?? .macDock) != .macDock, !dockAppliedState.isCustom {
            // 미복원 기록이 남아 있으면 새 적용은 거부된다 — 왜 못 누르는지 메뉴에서 보인다.
            apply.title = "Custom Dock 적용 (미복원 기록을 먼저 복원)"
        }
        submenu.addItem(apply)
        let restore = NSMenuItem(title: "기본 Dock으로 복원", action: #selector(restoreDockModeAction), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = restorable
        submenu.addItem(restore)
        // 사용자가 바꾼 항목은 **자동으로 지우지 않는다.** 정리하려면 이 항목을 쓴다(시스템 값은 건드리지 않는다).
        let userChanged = recovery.record?.entries.filter { $0.skipReason == DockRestoreDisposition.userChanged.rawValue
            || $0.skipReason == DockRestoreDisposition.keyRemoved.rawValue } ?? []
        if !userChanged.isEmpty {
            let forget = NSMenuItem(
                title: "사용자가 바꾼 항목 \(userChanged.count)개 기록에서 정리",
                action: #selector(forgetUserChangedAction),
                keyEquivalent: ""
            )
            forget.target = self
            forget.isEnabled = true
            submenu.addItem(forget)
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func add(to menu: NSMenu, title: String, action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @MainActor @objc private func togglePanelAction() {
        // 창을 띄우지 않는 상태에서는 메뉴 호출도 같은 규칙으로 안내한다.
        guard dockAppliedState.isCustom else {
            let selected = settings?.settings.dockMode
            model?.appendEvent("menu invoke blocked applied=none selected=\(selected?.rawValue ?? "none")")
            model?.setActionMessage(
                selected == .custom
                    ? "Custom 모드를 아직 적용하지 않았습니다 — 메뉴 › 사용 모드 › ‘Custom Dock 적용’."
                    : "Mac Dock 모드입니다 — 메뉴 › 사용 모드에서 Custom Dock을 선택·적용하세요."
            )
            return
        }
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
