import FocusProbeCore
import Foundation

// PaneDock 검증용 진단 CLI.
//
// 정상 경로: Ghostty + 로컬 셸 (공식 AppleScript).
// 실험 경로: herdr Adapter — 지원 범위 밖으로 제외된 코드다. 자세한 이유는 docs/scope-decisions.md.
//
// 금지 사항을 코드 구조로 강제한다(기획서 §5, 사용자 지시):
// - 이 프로세스의 PWD를 작업 경로로 쓰지 않는다. 경로는 연동이 보고한 값만 쓴다.
// - 호출한 pane(HERDR_PANE_ID)을 진단 목표로 쓰지 않는다. `--caller` 표시 전용이다.
// - 바깥 터미널이 보고한 경로를 중첩 TUI의 내부 경로로 표시하지 않는다.
// - 터미널에 입력을 보내거나, 앱을 활성화하거나, 화면을 읽지 않는다.

private let usage = """
focus-probe — PaneDock 검증용 진단 프로토타입

사용법:
  focus-probe [--once] [--json] [--interval <ms>]
  focus-probe --watch [--interval <ms>] [--json]
  focus-probe --self-test
  focus-probe --adapter cmux [--once|--watch] [--json]   (실험)
  focus-probe --adapter herdr [--once] [--socket <path>] [--caller]   (실험)

모드:
  --once        현재 대상 pane을 한 번 읽어 진단을 출력한다 (기본)
  --watch       변경을 따라가며 진단을 갱신한다
  --self-test   연동 없이 결정적 검사를 실행한다

옵션:
  --adapter <name>  ghostty(기본, 정상 경로) | cmux(실험) | herdr(실험, 지원 범위 밖)
  --interval <ms>   --watch 재조회 주기 (기본 1000)
  --json            기계 판독용 JSON 출력
  --socket <path>   herdr 소켓 경로 (--adapter herdr 전용)
  --caller          호출한 pane(HERDR_PANE_ID)을 참고용으로 표시 (--adapter herdr 전용)
  --help            이 도움말

상태 값:
  focus      tracked(포커스·경로 유효) held(마지막 위치 유지) pending(경로 확인 중) unknown(확인 불가)
  validity   valid pending missing unsupported
  connection connected unavailable refused denied incompatible

한계:
  대상 terminal에서 herdr/tmux 같은 중첩 TUI가 돌고 있으면 보고되는 경로는
  바깥 프로세스의 cwd이며 그 TUI의 내부 프로젝트 경로가 아니다.
  공식 조회로 중첩 여부를 확실히 판별할 수 없으므로 자동 감지하지 않는다.

cmux (실험):
  cmux는 공식 소켓 API로 선택된 surface와 그 경로를 제공한다. 이 도구는 공식 CLI의
  **읽기 명령 두 개만** 실행한다(identify, sidebar-state). workspace·pane·surface를
  만들거나 포커스를 바꾸지 않고, 앱을 활성화하지도 않는다.
  경로는 sidebar-state의 focused_cwd에서만 온다. 같은 응답의 cwd는 workspace 요약이므로
  쓰지 않는다. focused_panel이 선택된 surface와 다르면 경로를 인정하지 않는다.
  AppleScript는 쓰지 않는다 — 사전은 있지만 객체 모델이 응답하지 않는다(V11 실측).
  cmux가 실행 중이어야 하고, 소켓 접근 모드가 허용해야 한다(이 도구는 설정을 바꾸지 않는다).
  비활성 panel의 경로를 읽는 공식 방법이 없어 배경 관측은 하지 않는다.
"""

private enum AdapterKind: String {
    case ghostty
    case cmux
    case herdr
}

private struct Options {
    var adapter: AdapterKind = .ghostty
    var watch = false
    var selfTest = false
    var json = false
    var showCaller = false
    var socketPath: String?
    var intervalMilliseconds = 1000
}

private func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--once":
            break
        case "--watch":
            options.watch = true
        case "--self-test":
            options.selfTest = true
        case "--json":
            options.json = true
        case "--caller":
            options.showCaller = true
        case "--help", "-h":
            return nil
        case "--adapter":
            index += 1
            guard index < arguments.count, let kind = AdapterKind(rawValue: arguments[index]) else {
                FileHandle.standardError.write(Data("--adapter requires ghostty|cmux|herdr\n".utf8))
                exit(2)
            }
            options.adapter = kind
        case "--socket":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("--socket requires a path\n".utf8))
                exit(2)
            }
            options.socketPath = arguments[index]
        case "--interval":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--interval requires milliseconds\n".utf8))
                exit(2)
            }
            options.intervalMilliseconds = value
        default:
            FileHandle.standardError.write(Data("unknown option: \(argument)\n".utf8))
            exit(2)
        }
        index += 1
    }
    return options
}

/// 대상과 경로가 모두 확인됐을 때만 0. 스크립트에서 쓸 수 있게 한다.
private func exitCode(connection: ConnectionStatus, pathStatus: PathStatus?) -> Int32 {
    (connection == .connected && pathStatus == .valid) ? 0 : 1
}

// MARK: - 진입점

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    print(usage)
    exit(0)
}

if options.selfTest {
    let results = SelfTest.run()
    for result in results { emit(result.line) }
    let failed = results.filter { !$0.passed }.count
    emit("")
    emit("\(results.count - failed)/\(results.count) checks passed")
    exit(failed == 0 ? 0 : 1)
}

switch options.adapter {
case .ghostty, .cmux:
    // 두 앱 모두 공식 AppleScript 사전만 쓴다. 스키마·파서·반영 코드를 공유한다.
    let adapter: TerminalHostAdapter = options.adapter == .cmux ? CmuxAdapter() : GhosttyAdapter()
    if options.adapter == .cmux {
        FileHandle.standardError.write(
            Data("warning: --adapter cmux is experimental. Read-only socket CLI (identify, sidebar-state).\n".utf8)
        )
    }

    if options.watch {
        if !options.json {
            emit("focus-probe watch — adapter \(adapter.appName) (로컬 GUI \(adapter.appName))")
            emit("\(adapter.appName)에서 패널/workspace를 전환하거나 대상 셸에서 cd 하면 아래가 갱신된다. 종료는 Ctrl-C.")
        }
        WatchProbe(
            probe: GhosttyProbe(adapter: adapter),
            intervalMilliseconds: options.intervalMilliseconds,
            json: options.json
        ).run()
        exit(0)
    }

    let probe = GhosttyProbe(adapter: adapter)
    probe.refresh()
    let result = probe.diagnostic()
    emit(options.json ? DiagnosticsReport.renderJSON(result) : DiagnosticsReport.render(result))
    printFailure(probe.store)
    exit(exitCode(connection: probe.store.connection, pathStatus: probe.store.current?.pathStatus))

case .herdr:
    // 실험 경로. 지원 범위 밖이며 새 정상 경로가 아니다.
    let socketPath = resolveHerdrSocketPath(options.socketPath)
    if !options.json {
        FileHandle.standardError.write(
            Data("warning: --adapter herdr is experimental and outside the supported scope (docs/scope-decisions.md)\n".utf8)
        )
    }

    if options.watch {
        if !options.json {
            emit("focus-probe watch — socket \(socketPath) [herdr, experimental]")
        }
        HerdrWatchProbe(
            socketPath: socketPath,
            intervalMilliseconds: options.intervalMilliseconds,
            json: options.json,
            showCaller: options.showCaller
        ).run()
        exit(0)
    }

    let probe = HerdrOnceProbe(
        socketPath: socketPath,
        showCaller: options.showCaller,
        timeout: TimeInterval(options.intervalMilliseconds) / 1000.0
    )
    let result = probe.run()
    emit(options.json ? DiagnosticsReport.renderJSON(result) : DiagnosticsReport.render(result))
    printFailure(probe.store)
    exit(exitCode(connection: probe.store.connection, pathStatus: probe.store.current?.pathStatus))
}

private func printFailure(_ store: ContextStore) {
    if let failure = store.lastFailure, store.connection != .connected || store.current?.pathStatus != .valid {
        emit("")
        emit("failure    \(failure)")
    }
}
