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

guard let options = parseLaunchOptions(Array(CommandLine.arguments.dropFirst())) else {
    print(usageText)
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

    // 프로젝트 판정 (카탈로그가 있을 때만)
    let catalogStore = ProjectCatalogStore(url: projectCatalogURL(for: options))
    let resolution = snapshot.current.reportedCWD.flatMap {
        ProjectResolver.resolve(cwd: $0, catalog: catalogStore.catalog, catalogDiagnostics: catalogStore.diagnostics)
    }
    if let resolution {
        print("project     \(resolution.projectName) (\(resolution.projectID)) links=\(resolution.links.count)")
        for link in resolution.links {
            print("  link      \(link.name) → \(ProjectLinkPrivacy.redactedForLog(link.url))")
        }
    } else {
        print("project     - (기본 Dock) catalog=\(catalogStore.outcome.label) projects=\(catalogStore.catalog.projects.count)")
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
