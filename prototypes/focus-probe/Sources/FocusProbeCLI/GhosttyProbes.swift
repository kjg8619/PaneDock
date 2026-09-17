import FocusProbeCore
import Foundation

// 정상 실행 경로: Ghostty + 로컬 셸 (공식 AppleScript).
// 실험 경로: cmux — 공식 소켓 CLI(`identify`, `sidebar-state`). AppleScript는 쓸 수 없다(V11).
//
// 조회 자체는 `FocusProbeCore.GhosttyProbe`가 담당한다. 이 파일에는 CLI만의 폴링 루프만 둔다.
// Ghostty에도 cmux에도 구독 API가 없으므로 폴링이 유일한 수단이다.
//
// 알려진 한계(자동 감지하지 않음): 대상 terminal에서 herdr/tmux 같은 중첩 TUI가 돌고 있으면
// `working directory`는 **바깥 프로세스의 cwd**이고 그 TUI의 내부 프로젝트 경로가 아니다.
// 공식 조회로 중첩 여부를 확실히 판별할 수 없으므로 감지했다고 주장하지 않는다.

/// 주기적으로 다시 조회한다.
final class WatchProbe {
    private let probe: GhosttyProbe
    private let renderer: ChangeRenderer
    private let intervalMilliseconds: Int

    init(probe: GhosttyProbe, intervalMilliseconds: Int, json: Bool) {
        self.probe = probe
        self.renderer = ChangeRenderer(json: json)
        self.intervalMilliseconds = intervalMilliseconds
    }

    func run() {
        while true {
            let reason: String
            switch probe.refresh() {
            case .startup: reason = "startup"
            case .unchanged: reason = "poll"
            case .changed: reason = "poll → focus changed"
            }
            renderer.render(probe.diagnostic(), reason: reason)
            Thread.sleep(forTimeInterval: TimeInterval(intervalMilliseconds) / 1000.0)
        }
    }
}
