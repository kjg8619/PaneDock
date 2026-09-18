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
func renderDockRestoreResult(options: LaunchOptions) -> String {
    let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("PaneDock", isDirectory: true)
    let store = DockRecoveryStore(url: support?.appendingPathComponent("dock-recovery.json"))
    let controller = DockModeController(
        system: SystemDockControl(),
        recovery: store,
        lock: DockModeLock(url: support?.appendingPathComponent("dock-mode.lock"))
    )
    switch controller.recoveryState() {
    case .unreadable(let reason):
        // 손상된 기록을 '없음'으로 뭉개지 않는다(복구 수단이 조용히 사라지면 안 된다).
        return "dock restore: unreadable record (\(reason)) — " + (store.url?.path ?? "-") + " 파일을 지우지 않았습니다"
    case .noPath:
        return "dock restore: 복구 기록 경로가 없습니다(앱 지원 폴더를 만들 수 없음)"
    case .none, .record:
        break
    }
    if let record = controller.detectStaleRecord() {
        do {
            let outcome = try controller.restoreToMacDock()
            return "dock restore: mode=\(record.mode) restored=\(outcome.changedKeys.count) "
                + "skipped=\(outcome.skippedByUserChange.count) left=\(outcome.recoveryRecordLeft)"
        } catch let error as DockModeError {
            return "dock restore: failed reason=\(error.message)"
        } catch {
            return "dock restore: failed"
        }
    }
    return "dock restore: nothing to restore (복구 기록 없음)"
}

guard let options = parseLaunchOptions(Array(CommandLine.arguments.dropFirst())) else {
    print(usageText)
    exit(0)
}

// GUI 없이 실행하는 Dock 복구. **다시 Custom 모드로 들어가지 않는다.**
if options.restoreDock {
    print(renderDockRestoreResult(options: options))
    exit(0)
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
