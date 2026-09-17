import FocusProbeCore
import Foundation

struct LaunchOptions {
    /// 가짜 입력 모드. 값이 있으면 실제 Ghostty에 붙지 않는다.
    var fake: FakeAppleScriptRunner.Scenario?
    var intervalMilliseconds = 1000
    /// 창을 띄우지 않고 1회 조회 결과만 출력한다.
    var selfCheck = false
    /// 창을 띄우되 화면에 올리지 않는다(상태바 항목으로 다시 표시).
    var hidden = false
    /// 지정하면 상태가 갱신될 때마다 한 줄씩 append 한다(화면을 읽지 않고 동작을 확인하기 위한 진단용).
    var stateLogPath: String?
    /// 설정 파일 경로 재정의. 없으면 기본 경로를 쓴다. 가짜 모드는 항상 메모리 전용이다.
    var settingsPath: String?
    /// 프로젝트 카탈로그 경로 재정의. 없으면 기본 경로를 쓴다.
    var projectsPath: String?
    /// 진단용: 시작 직후 창을 이 좌표로 옮긴다. 사용자가 창을 드래그한 것과 **같은 경로**를 탄다.
    var moveTo: CGPoint?
    /// 진단용: 시작 후 이 시간(ms) 뒤에 메뉴의 "프로젝트 설정 다시 읽기"와 **같은 동작**을 한 번 수행한다.
    var reloadAfterMilliseconds: Int?
    /// 진단용: 상세 보기를 연 상태로 시작한다(스크린샷·확인용).
    var detailsAtLaunch = false
    /// 진단용: 편집창을 연 상태로 시작한다(스크린샷·확인용).
    var editorAtLaunch = false
    /// 진단용: 시작 후 이 시간(ms) 뒤에 **편집 초안에 항목 하나를 추가하고 저장**한다.
    /// 임시 카탈로그(`--projects-path`)에서만 쓴다.
    var editorSelfTestAfterMilliseconds: Int?
    /// 진단용: 시작 후 이 시간(ms) 뒤에 **편집만 하고 취소**한다(저장된 구성이 바뀌지 않는지 확인).
    var editorCancelAfterMilliseconds: Int?
    /// 추적할 터미널 소스. 기본은 자동(최전면 앱을 따라간다).
    var hostSource: HostSource = .auto

    var isFake: Bool { fake != nil }
}

/// 추적할 터미널 소스.
///
/// `auto`는 **최전면 앱을 따라간다**: Ghostty가 앞에 있으면 Ghostty, cmux가 앞에 있으면 cmux,
/// 둘 다 뒤에 있으면 마지막 대상을 유지한다. 판정할 수 없으면 기본 호스트(Ghostty)로 시작한다.
enum HostSource: String, CaseIterable {
    case auto
    case ghostty
    case cmux

    var label: String {
        switch self {
        case .auto: return "자동"
        case .ghostty: return "Ghostty"
        case .cmux: return "cmux"
        }
    }
}

let usageText = """
PaneDock — 포커스된 터미널 pane을 따라가는 최소 Dock

사용법:
  PaneDock [--interval <ms>] [--hidden] [--adapter <auto|ghostty|cmux>]
  PaneDock --fake <steady|toggle|missing>
  PaneDock --self-check [--fake <scenario>] [--adapter <auto|ghostty|cmux>]

옵션:
  --interval <ms>   재조회 주기 (기본 1000)
  --hidden          창을 화면에 올리지 않고 시작(메뉴 막대에서 다시 표시)
  --adapter <name>  추적 소스. auto(기본)=최전면 앱을 따라간다 | ghostty | cmux
  --fake <mode>     가짜 입력 모드. 실제 터미널에 붙지 않으며 창에 [FAKE]로 표시된다
  --self-check      창을 띄우지 않고 1회 조회 결과와 실행 계획만 출력한다
  --help            이 도움말

추적 소스:
  auto   Ghostty가 앞에 있으면 Ghostty, cmux가 앞에 있으면 cmux를 따른다.
         둘 다 앞에 없으면 마지막 대상을 "유지 중"으로 남긴다.
  ghostty / cmux   그 터미널만 따른다(자동 전환 없음).

범위:
  각 터미널의 직접 pane과 로컬 셸만 대상으로 한다.
  다중 창, 중첩 멀티플렉서(herdr·tmux), SSH 내부 경로는 지원하지 않는다.

상태:
  추적 중(tracked) 유지 중(held) 잠금(locked) 확인 중(pending) 오류(error)
"""

func parseLaunchOptions(_ arguments: [String]) -> LaunchOptions? {
    var options = LaunchOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--fake":
            index += 1
            guard index < arguments.count, let scenario = FakeAppleScriptRunner.Scenario(rawValue: arguments[index]) else {
                FileHandle.standardError.write(Data("--fake requires steady|toggle|missing\n".utf8))
                exit(2)
            }
            options.fake = scenario
        case "--interval":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--interval requires milliseconds\n".utf8))
                exit(2)
            }
            options.intervalMilliseconds = value
        case "--self-check":
            options.selfCheck = true
        case "--settings-path":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("--settings-path requires a path\n".utf8))
                exit(2)
            }
            options.settingsPath = arguments[index]
        case "--projects-path":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("--projects-path requires a path\n".utf8))
                exit(2)
            }
            options.projectsPath = arguments[index]
        case "--state-log":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("--state-log requires a path\n".utf8))
                exit(2)
            }
            options.stateLogPath = arguments[index]
        case "--hidden":
            options.hidden = true
        case "--adapter":
            index += 1
            guard index < arguments.count, let source = HostSource(rawValue: arguments[index]) else {
                FileHandle.standardError.write(Data("--adapter requires auto|ghostty|cmux\n".utf8))
                exit(2)
            }
            options.hostSource = source
        case "--details":
            options.detailsAtLaunch = true
        case "--editor":
            options.editorAtLaunch = true
        case "--editor-selftest":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--editor-selftest requires milliseconds\n".utf8))
                exit(2)
            }
            options.editorSelfTestAfterMilliseconds = value
        case "--editor-cancel-after":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--editor-cancel-after requires milliseconds\n".utf8))
                exit(2)
            }
            options.editorCancelAfterMilliseconds = value
        case "--move-to":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(Data("--move-to requires x,y\n".utf8))
                exit(2)
            }
            let parts = arguments[index].split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                FileHandle.standardError.write(Data("--move-to requires x,y\n".utf8))
                exit(2)
            }
            options.moveTo = CGPoint(x: x, y: y)
        case "--reload-after":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--reload-after requires milliseconds\n".utf8))
                exit(2)
            }
            options.reloadAfterMilliseconds = value
        case "--help", "-h":
            return nil
        default:
            FileHandle.standardError.write(Data("unknown option: \(arguments[index])\n".utf8))
            exit(2)
        }
        index += 1
    }
    return options
}

/// 추적 소스를 만든다.
///
/// - `auto`(기본): 최전면 앱이 Ghostty면 Ghostty, cmux면 cmux. 둘 다 뒤에 있으면 마지막 대상을
///   유지하고, 아직 고른 적이 없으면 Ghostty로 시작한다(`TerminalHostRouter`).
/// - `ghostty` / `cmux`: 그 호스트만 따른다(자동 전환 없음).
/// - **가짜 모드는 라우팅하지 않는다.** 결정적 검사를 위해 Ghostty 스텁 하나만 쓴다.
func makeHostAdapter(_ options: LaunchOptions) -> TerminalHostAdapter {
    if let fake = options.fake {
        return GhosttyAdapter(runner: FakeAppleScriptRunner(scenario: fake))
    }
    switch options.hostSource {
    case .ghostty:
        return GhosttyAdapter()
    case .cmux:
        return CmuxAdapter()
    case .auto:
        return TerminalHostRouter(
            hosts: [
                TerminalHostRouter.Host(
                    adapter: GhosttyAdapter(),
                    bundleIdentifier: GhosttyAdapter.bundleIdentifier
                ),
                TerminalHostRouter.Host(
                    adapter: CmuxAdapter(),
                    bundleIdentifier: CmuxAdapter.bundleIdentifier
                ),
            ]
        )
    }
}

/// 프로젝트 카탈로그 경로. `--projects-path` > 기본 경로. 가짜 모드는 파일을 쓰지 않는다.
func projectCatalogURL(for options: LaunchOptions) -> URL? {
    if let override = options.projectsPath {
        return URL(fileURLWithPath: override)
    }
    if options.isFake {
        return nil
    }
    return FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("PaneDock", isDirectory: true)
        .appendingPathComponent("projects.json")
}
