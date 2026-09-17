import FocusProbeCore
import Foundation

/// 가짜 입력 모드.
///
/// 실제 Ghostty에 붙지 않는다. UI는 이 모드를 **명시적으로** 표시한다(배너 + 창 제목).
/// 실제 연결 모드와 절대 섞이지 않는다: `LaunchOptions.fake`가 있을 때만 생성된다.
final class FakeAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    enum Scenario: String {
        /// 한 대상에 고정. 경로는 실제로 존재하는 디렉터리.
        case steady
        /// 몇 번의 조회마다 대상을 바꾼다(A/B 시연).
        case toggle
        /// 경로를 제공하지 않는 pane(C: 비활성 pane 확인용 아님, 오류 상태 확인용).
        case missing
    }

    private let scenario: Scenario
    private var callCount = 0

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func run(_ source: String) throws -> String {
        callCount += 1

        switch scenario {
        case .steady:
            return output(focused: "term-A", terminals: [
                (id: "term-A", wd: "/tmp", name: "fake-A"),
                (id: "term-B", wd: NSHomeDirectory(), name: "fake-B"),
            ])

        case .toggle:
            // 3회마다 대상이 바뀐다. 첫 조회는 A.
            let useA = ((callCount - 1) / 3) % 2 == 0
            return output(focused: useA ? "term-A" : "term-B", terminals: [
                (id: "term-A", wd: "/tmp", name: "fake-A"),
                (id: "term-B", wd: NSHomeDirectory(), name: "fake-B"),
            ])

        case .missing:
            return output(focused: "term-A", terminals: [
                (id: "term-A", wd: "", name: "fake-no-path"),
                (id: "term-B", wd: NSHomeDirectory(), name: "fake-B"),
            ])
        }
    }

    private func output(focused: String, terminals: [(id: String, wd: String, name: String)]) -> String {
        var lines = [
            "version=1.3.1",
            "frontmost=true",
            "frontWindow=win-fake",
            "selectedTab=tab-fake",
            "focusedTerminal=\(focused)",
            "focusedWD=\(terminals.first { $0.id == focused }?.wd ?? "")",
        ]
        for terminal in terminals {
            lines.append("term=win-fake\ttab-fake\t\(terminal.id)\t\(terminal.wd)\t\(terminal.name)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
