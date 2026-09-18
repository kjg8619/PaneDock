import AppKit
import FocusProbeCore
import Foundation

// PaneDock — Ghostty 전용 최소 Dock (0.1a)
//
// 범위: Ghostty 한 창의 직접 pane과 로컬 셸.
// 제외: 다중 창, 중첩 멀티플렉서(herdr·tmux), SSH 내부 경로, 전역 단축키, 테마, 위젯.
//
// 추적 로직은 FocusProbeCore를 그대로 쓴다(CLI 진단 도구와 같은 코드). 복제하지 않는다.
// CLI의 사람이 읽는 출력 문자열을 파싱하지 않는다. 여기서는 값(DockState)만 다룬다.

// Dock 복구는 GUI를 띄우지 않는다(비정상 종료 뒤에도 쓸 수 있는 수단).
//
// 종료 코드: 0 = 완전 복원(또는 되돌릴 것 없음) · 2 = 부분 복원 · 3 = 실패(손상·잠금·쓰기 실패).
// 부분 복원과 실패를 0으로 돌려주지 않는다(스크립트가 구분할 수 있어야 한다).
func runDockRestore(options: LaunchOptions) -> (line: String, code: Int32) {
    let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("PaneDock", isDirectory: true)
    let recoveryURL = support?.appendingPathComponent("dock-recovery.json")
    let store = DockRecoveryStore(url: recoveryURL)
    let controller = DockModeController(
        system: SystemDockControl(allowRestart: !options.noDockRestart),
        recovery: store,
        lock: DockModeLock(url: support?.appendingPathComponent("dock-mode.lock"))
    )
    if case .unreadable(let reason) = controller.recoveryState() {
        // 손상된 기록을 '없음'으로 뭉개지 않는다(복구 수단이 조용히 사라지면 안 된다).
        return (
            "dock restore: failed reason=unreadable-record(\(reason)) file=\(recoveryURL?.path ?? "-") — 파일을 지우지 않았습니다",
            3
        )
    }
    do {
        let outcome = try controller.restoreToMacDock()
        let code: Int32 = switch outcome.kind {
        case .nothingToDo, .complete: 0
        case .partial: 2
        case .failed: 3
        }
        return (outcome.summaryLine, code)
    } catch let error as DockModeError {
        return ("dock restore: failed reason=\(error.message)", 3)
    } catch {
        return ("dock restore: failed", 3)
    }
}

// 읽기 전용 확인: 계획 키의 값·자료형을 **바꾸지 않고** 본다(자료형 보존 확인용).
func renderDockProbe(extraKeys: [String]) -> String {
    let control = SystemDockControl(allowRestart: false)
    let plan = DockModePlan.systemDefault
    var lines = ["dock probe: (읽기 전용, 아무것도 바꾸지 않음)"]
    let changes = plan.hideKeys + plan.suppressionKeys
    // 함께 준 키도 같은 방식으로 읽는다(자료형 확인용).
    for text in extraKeys {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.count == 2
            ? DockPreferenceKey(domain: parts[0], name: parts[1])
            : DockPreferenceKey(domain: "com.apple.dock", name: parts[0])
        let current = control.currentValue(for: key)
        lines.append("  \(key.label) = \(current?.text ?? "없음")/\(current?.typeName ?? "-")")
    }
    for change in changes {
        let current = control.currentValue(for: change.key)
        lines.append(
            "  \(change.key.label) = \(current?.text ?? "없음")/\(current?.typeName ?? "-") "
                + "목표=\(change.value.text)/\(change.value.typeName) "
                + "이미목표=\(current.map { $0.matches(change.value) } ?? false)"
        )
    }
    return lines.joined(separator: "\n")
}

guard let options = parseLaunchOptions(Array(CommandLine.arguments.dropFirst())) else {
    print(usageText)
    exit(0)
}

// GUI 없이 실행하는 Dock 복구. **다시 Custom 모드로 들어가지 않는다.**
// 사용자 변경 항목 정리(시스템 값은 건드리지 않는다). 종료 코드: 0 = 정리됨, 3 = 실패.
func runForgetUserChanged(options: LaunchOptions) -> (line: String, code: Int32) {
    let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("PaneDock", isDirectory: true)
    let store = DockRecoveryStore(url: support?.appendingPathComponent("dock-recovery.json"))
    let controller = DockModeController(
        system: SystemDockControl(allowRestart: false),
        recovery: store,
        lock: DockModeLock(url: support?.appendingPathComponent("dock-mode.lock"))
    )
    switch controller.recoveryState() {
    case .none:
        return ("dock forget: nothing to do (복구 기록 없음)", 0)
    case .noPath:
        return ("dock forget: failed reason=no-path", 3)
    case .unreadable(let reason):
        return ("dock forget: failed reason=unreadable-record(\(reason)) — 파일을 지우지 않았습니다", 3)
    case .record(let record):
        let result = controller.forgetUserChanged(operationID: record.operationID)
        switch result {
        case .written:
            let left = store.load()?.pendingKeyLabels ?? []
            return ("dock forget: ok left=\(left.count) \(left.joined(separator: ","))", 0)
        case .refusedPendingRestore(let keys):
            return ("dock forget: failed reason=refused(\(keys.joined(separator: ",")))", 3)
        case .refusedUnreadable(let reason):
            return ("dock forget: failed reason=unreadable(\(reason))", 3)
        case .failed(let reason):
            return ("dock forget: failed reason=\(reason)", 3)
        case .noPath:
            return ("dock forget: failed reason=no-path", 3)
        }
    }
}

if options.forgetUserChanged {
    let result = runForgetUserChanged(options: options)
    print(result.line)
    exit(result.code)
}

if options.dockProbe {
    print(renderDockProbe(extraKeys: options.dockProbeKeys))
    exit(0)
}

if options.restoreDock {
    let result = runDockRestore(options: options)
    print(result.line)
    exit(result.code)
}

// 창을 띄우지 않고 1회만 확인한다. GUI를 실제로 띄우지 않고도 상태·계획을 검증할 수 있다.
if options.selfCheck {
    let probe = GhosttyProbe(adapter: makeHostAdapter(options))
    _ = probe.refresh()
    let snapshot = probe.diagnostic()
    let state = DockStateBuilder.make(
        current: snapshot.current,
        previous: snapshot.previous,
        connection: snapshot.current.connectionStatus,
        failure: probe.store.lastFailure,
        lock: DockLock()
    )

    print("mode        \(options.isFake ? "fake(\(options.fake!.rawValue))" : "live")")
    print("adapter     \(options.hostSource.rawValue)")
    print("display     \(state.display.rawValue)")
    print("folderName  \(state.folderName)")
    print("fullPath    \(state.fullPath ?? "-")")
    print("previous    \(state.previousPath ?? "-")")
    print("paneID      \(state.paneID ?? "-")")
    print("host        \(state.hostAppID ?? "-")")
    print("cwdSource   \(snapshot.current.cwdSource?.rawValue ?? "-")")
    print("frontmost   \(state.hostFrontmost.map(String.init) ?? "-")")
    print("detail      \(state.detail ?? "-")")

    // 항목 판정 (카탈로그가 있을 때만)
    let catalogStore = ProjectCatalogStore(url: projectCatalogURL(for: options))
    let resolution = ProjectResolver.resolve(
        cwd: snapshot.current.reportedCWD ?? "",
        catalog: catalogStore.catalog,
        catalogDiagnostics: catalogStore.diagnostics
    )
    let projectLabel = resolution.hasProject
        ? "\(resolution.projectName) (\(resolution.projectID))"
        : "- (기본 Dock)"
    print("project     \(projectLabel) catalog=\(catalogStore.outcome.label) projects=\(catalogStore.catalog.projects.count)")
    print("items       공통 \(resolution.commonItems.count)개 · 프로젝트 \(resolution.projectItems.count)개")
    for item in resolution.allItems {
        let scope = item.isCommon ? "공통" : "프로젝트"
        let logTarget = item.kind == .link ? ProjectLinkPrivacy.redactedForLog(item.target) : item.target
        print("  item      [\(scope)] \(item.kind.rawValue) \(item.name) → \(logTarget)")
    }
    for diagnostic in catalogStore.diagnostics.prefix(3) {
        print("warning     \(diagnostic)")
    }

    print("openPlan    \(DockActionPlanner.plan(.openFolder, for: snapshot.current, validator: FileSystemPathValidator()))")
    print("copyPlan    \(DockActionPlanner.plan(.copyPath, for: snapshot.current, validator: FileSystemPathValidator()))")
    exit(state.display == .error ? 1 : 0)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = PaneDockAppDelegate(options: options)
application.delegate = delegate
application.run()
