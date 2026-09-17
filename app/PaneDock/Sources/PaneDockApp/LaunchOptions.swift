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

    var isFake: Bool { fake != nil }
}

let usageText = """
PaneDock — Ghostty 전용 최소 Dock (0.1a)

사용법:
  PaneDock [--interval <ms>] [--hidden]
  PaneDock --fake <steady|toggle|missing>
  PaneDock --self-check [--fake <scenario>]

옵션:
  --interval <ms>   재조회 주기 (기본 1000)
  --hidden          창을 화면에 올리지 않고 시작(메뉴 막대에서 다시 표시)
  --fake <mode>     가짜 입력 모드. 실제 Ghostty에 붙지 않으며 창에 [FAKE]로 표시된다
  --self-check      창을 띄우지 않고 1회 조회 결과와 실행 계획만 출력한다
  --help            이 도움말

범위:
  Ghostty 한 창의 직접 pane과 로컬 셸만 대상으로 한다.
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

/// 가짜 모드와 실제 연결 모드를 명확히 가른다. 가짜일 때만 스텁 러너를 쓴다.
func makeGhosttyAdapter(_ options: LaunchOptions) -> GhosttyAdapter {
    if let fake = options.fake {
        return GhosttyAdapter(runner: FakeAppleScriptRunner(scenario: fake))
    }
    return GhosttyAdapter()
}
