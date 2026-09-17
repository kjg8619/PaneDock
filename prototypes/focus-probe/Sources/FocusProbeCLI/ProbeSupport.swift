import FocusProbeCore
import Foundation

// Adapter에 무관한 CLI 공통 조각.

func emit(_ text: String) {
    print(text)
    fflush(stdout) // 파이프로 넘길 때도 즉시 보이도록 한다.
}

/// 대상이 정해지기 전의 자리 표시자. 경로를 추측으로 채우지 않는다.
func unknownInfo(factory: WorkInfoFactory, generation: UInt64, connection: ConnectionStatus) -> CurrentWorkInfo {
    factory.unresolvedWorkInfo(generation: generation, connection: connection)
}

/// 변경이 있을 때만 블록을 출력한다.
///
/// 마지막 확인 시각은 매번 바뀌므로 `DiagnosticsReport.changeKey`가 그 필드를 제외한다.
final class ChangeRenderer {
    private var lastKey: String?
    private let json: Bool

    init(json: Bool) {
        self.json = json
    }

    /// 바뀐 경우에만 출력하고 true를 돌려준다.
    @discardableResult
    func render(_ snapshot: DiagnosticSnapshot, reason: String) -> Bool {
        let key = DiagnosticsReport.changeKey(snapshot)
        guard key != lastKey else { return false }
        lastKey = key

        let payload = json ? DiagnosticsReport.renderJSON(snapshot) : DiagnosticsReport.render(snapshot)
        let stamp = ISO8601DateFormatter().string(from: Date())
        if json {
            emit("{\"at\":\"\(stamp)\",\"reason\":\"\(reason)\",\"diagnostics\":\(payload)}")
        } else {
            emit("")
            emit("── \(stamp)   \(reason)")
            emit(payload)
        }
        return true
    }
}

// MARK: - herdr 전용 옵션 (실험 경로에서만 쓴다)

func resolveHerdrSocketPath(_ override: String?) -> String {
    if let override { return override }
    if let fromEnvironment = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !fromEnvironment.isEmpty {
        return fromEnvironment
    }
    return NSHomeDirectory() + "/.config/herdr/herdr.sock"
}

/// 호출한 pane — 표시 참고용. 진단 목표로 승격하지 않는다.
func callerPaneID(show: Bool) -> String? {
    guard show else { return nil }
    return ProcessInfo.processInfo.environment["HERDR_PANE_ID"]
}
