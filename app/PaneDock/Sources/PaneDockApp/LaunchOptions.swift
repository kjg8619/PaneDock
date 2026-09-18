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
    /// 진단용: 집중 타이머의 기본 시간(초)을 바꾼다. **완료(00:00) 상태를 실제 화면에서 확인**하기 위한 것이다.
    /// 값이 없으면 25분(제품 기본값)이다.
    var timerSecondsOverride: Int?
    /// 진단용: 시작 후 이 시간(ms) 뒤에 첫 집중 타이머를 **시작**한다(입력 없이 완료 상태까지 관측하기 위한 것).
    var timerAutostartAfterMilliseconds: Int?
    /// 진단용: 시작 후 이 시간(ms) 뒤에 **키보드 경로**(초점 이동 → 활성화)를 순서대로 실행한다.
    /// macOS가 합성 키로 앱을 활성화하지 못하게 하므로, 키가 들어왔을 때 타는 같은 함수를 부른다.
    var keyboardSelfTestAfterMilliseconds: Int?

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
  --timer-seconds <n>  (진단용) 집중 타이머 기본 시간(초). 완료 상태 확인용
  --timer-autostart <ms>  (진단용) 시작 후 이 시간 뒤에 첫 타이머를 시작한다
  --key-selftest <ms>  (진단용) 시작 후 이 시간 뒤에 키보드 경로(초점 이동→활성화)를 실행한다
  --help            이 도움말

추적 소스:
  auto   Ghostty가 앞에 있으면 Ghostty, cmux가 앞에 있으면 cmux를 따른다.
         둘 다 앞에 없으면 마지막 대상을 "유지 중"으로 남긴다.
  ghostty / cmux   그 터미널만 따른다(자동 전환 없음).

범위:
  각 터미널의 직접 pane과 로컬 셸만 대상으로 한다.
  다중 창, 중첩 멀티플렉서(herdr·tmux), SSH 내부 경로는 지원하지 않는다.

빌드 확인:
  상세 보기의 '빌드' 줄, 또는 시작 로그의 build=[...] — 제품 버전 · 빌드 번호 · 커밋 · 작업 트리 상태.
  **개인 실사용 빌드**다. 공개 배포 준비(서명·공증·설치 안내)는 되어 있지 않다.

처음 쓰기:
  1) 빌드:   bash app/PaneDock/make-app.sh      (개발 중에는 swift build)
  2) 실행:   open app/PaneDock/dist/PaneDock.app   (메뉴 막대 PaneDock 아이콘)
  3) 호출:   ⌃⌥⌘D → Tab으로 이동 → Enter로 실행 → Esc로 닫기(상세 보기가 열려 있으면 그것부터 닫힌다)
  4) 편집:   Dock 위 ⋯ 메뉴 또는 상세 보기의 'Dock 편집…' — 항목·배치(순서·영역 폭·카드)를 바꾸고 저장
  5) 등록:   미등록 경로에서 패널의 '프로젝트로 등록' → 기준 폴더를 지정하면 그 경로에서 자동 전환
  6) 종료:   메뉴 막대 › PaneDock 종료 (⌘Q)

연동 전제:
  Ghostty 1.3.0+ — 공식 AppleScript로 포커스 pane과 경로를 읽는다. 셸 설정 변경·별도 설치가 필요 없다.
  cmux — **CLI가 설치돼 있고 소켓 접근이 허용된 환경**에서만 읽는다(읽기 전용 socket CLI: identify · sidebar-state).
  설치돼 있어도 소켓 접근이 준비되지 않으면 연결되지 않는다(그때는 '미실행' 또는 '연결 실패'로 표시).
  중첩 TUI(herdr·tmux) 내부 경로는 공식 조회로 알 수 없다.

현재 제한:
  프로젝트 전환은 **영역만** 바뀐다(전체 Dock 프로필 전환 없음) · 타이머 상태는 앱 종료 후 복원되지 않는다 ·
  확인 중(pending) 화면은 실제 흐름에서 잠깐이라 캡처하지 못했다.
  키보드 조작(⌃⌥⌘D → Tab → Enter → Esc)은 사용자가 직접 확인했다(타이머 시작·⋯ 메뉴 열기 포함).

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
        case "--timer-seconds":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--timer-seconds requires seconds\n".utf8))
                exit(2)
            }
            options.timerSecondsOverride = value
        case "--timer-autostart":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--timer-autostart requires milliseconds\n".utf8))
                exit(2)
            }
            options.timerAutostartAfterMilliseconds = value
        case "--key-selftest":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                FileHandle.standardError.write(Data("--key-selftest requires milliseconds\n".utf8))
                exit(2)
            }
            options.keyboardSelfTestAfterMilliseconds = value
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
