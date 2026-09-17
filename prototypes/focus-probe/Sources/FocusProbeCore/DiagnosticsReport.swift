import Foundation

/// 진단 표시 문자열. 기획서가 요구한 "출처·연결 상태·마지막 확인 시각"을 담는다.
public enum DiagnosticsReport {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    public static func render(_ snapshot: DiagnosticSnapshot) -> String {
        let info = snapshot.current
        var lines: [String] = []
        lines.append(row("pane", "\(info.identity.paneID)   workspace \(info.identity.workspaceID)   tab \(info.identity.tabID)   terminal \(info.identity.terminalID ?? "-")"))
        if let title = info.title, !title.isEmpty {
            lines.append(row("title", title))
        }
        lines.append(row("focus", "\(info.focusStatus.rawValue)                     (focusGeneration \(info.focusGeneration))"))
        lines.append(row("path", info.reportedCWD ?? "-"))
        lines.append(row("cwdSource", info.cwdSource?.rawValue ?? "-"))
        lines.append(row("foreground", info.foregroundCWD ?? "-"))
        lines.append(row("validity", describe(info.pathStatus)))
        lines.append(row("observed", observedText(info)))
        lines.append(row("connection", connectionText(info, snapshot: snapshot)))
        lines.append(row("host", hostText(info, snapshot: snapshot)))
        lines.append(row("frontmost", frontmostText(info)))
        lines.append(row("previous", previousText(snapshot.previous)))
        for pane in snapshot.backgroundPanes {
            lines.append(row("background", backgroundText(pane)))
        }
        lines.append(row("nesting", "unknown            (중첩 TUI 내부 경로는 공식 조회로 알 수 없음)"))
        if let caller = snapshot.callerPaneID {
            lines.append(row("caller", "\(caller)   (호출한 pane. 진단 목표가 아니다)"))
        }
        return lines.joined(separator: "\n")
    }

    private static func hostText(_ info: CurrentWorkInfo, snapshot: DiagnosticSnapshot) -> String {
        let version = snapshot.hostVersion.map { " \($0)" } ?? ""
        return "\(info.identity.adapterID) / \(info.identity.hostAppID)\(version)"
    }

    private static func frontmostText(_ info: CurrentWorkInfo) -> String {
        switch info.hostFrontmost {
        case .some(true): return "true               (최전면)"
        case .some(false): return "false              (최전면 아님 — 마지막 위치 유지로 표시)"
        case .none: return "unknown            (연동이 제공하지 않음)"
        }
    }

    private static func backgroundText(_ pane: BackgroundPaneInfo) -> String {
        let path = pane.reportedCWD ?? "-"
        let title = pane.title.map { "   \($0)" } ?? ""
        return "\(pane.paneID)   \(path)   (\(pane.pathStatus.rawValue))\(title)"
    }

    private static func row(_ key: String, _ value: String) -> String {
        let padded = key.padding(toLength: max(key.count, 11), withPad: " ", startingAt: 0)
        return "\(padded) \(value)"
    }

    private static func describe(_ status: PathStatus) -> String {
        switch status {
        case .valid: return "valid              (디렉터리 확인됨)"
        case .pending: return "pending            (경로를 아직 받지 못함)"
        case .missing: return "missing            (보고된 경로가 파일 시스템에 없음)"
        case .unsupported: return "unsupported        (연동이 경로를 제공하지 않음)"
        }
    }

    private static func observedText(_ info: CurrentWorkInfo) -> String {
        let time = info.observedAt.map(timestampFormatter.string(from:)) ?? "-"
        let revision = info.sourceRevision.map(String.init) ?? "-"
        return "\(time)   revision \(revision)"
    }

    private static func connectionText(_ info: CurrentWorkInfo, snapshot: DiagnosticSnapshot) -> String {
        switch info.connectionStatus {
        case .connected:
            if let protocolVersion = snapshot.protocolVersion {
                return "connected          protocol \(protocolVersion) (expected \(snapshot.expectedProtocolVersion)) version \(snapshot.serverVersion ?? "-")"
            }
            return "connected          AppleScript (\(info.identity.hostAppID) \(snapshot.hostVersion ?? "-"))"
        case .unavailable:
            let detail = snapshot.socketPath == "-" ? "(앱 미실행 또는 조회 실패)" : snapshot.socketPath
            return "unavailable        \(detail)"
        case .refused:
            return "refused            (소켓은 있으나 응답 없음) \(snapshot.socketPath)"
        case .denied:
            return "denied             (자동화 권한 거부)"
        case .incompatible:
            if let protocolVersion = snapshot.protocolVersion {
                return "incompatible       protocol \(protocolVersion) != expected \(snapshot.expectedProtocolVersion)"
            }
            return "incompatible       AppleScript 미지원 (버전 또는 설정)"
        }
    }

    private static func previousText(_ previous: CurrentWorkInfo?) -> String {
        guard let previous else { return "-                  (이전 위치 없음)" }
        let path = previous.reportedCWD ?? "-"
        return "\(path)   (이전 위치. pane \(previous.identity.paneID))"
    }

    /// 표시 갱신 여부를 판단하는 키.
    ///
    /// 마지막 확인 시각(`observedAt`)은 **제외**한다. 매 조회마다 값이 바뀌므로
    /// 포함하면 같은 경로·같은 포커스인데도 매번 다시 출력된다.
    public static func changeKey(_ snapshot: DiagnosticSnapshot) -> String {
        let info = snapshot.current
        let previousPath = snapshot.previous?.reportedCWD ?? "-"
        return [
            info.identity.paneID,
            info.identity.workspaceID,
            info.identity.tabID,
            info.reportedCWD ?? "-",
            info.cwdSource?.rawValue ?? "-",
            info.foregroundCWD ?? "-",
            info.focusStatus.rawValue,
            info.pathStatus.rawValue,
            info.connectionStatus.rawValue,
            String(info.focusGeneration),
            String(info.sourceRevision ?? -1),
            previousPath,
            snapshot.serverVersion ?? "-",
            snapshot.hostVersion ?? "-",
            String(snapshot.protocolVersion ?? -1),
            info.hostFrontmost.map(String.init) ?? "-",
            snapshot.backgroundPanes
                .map { "\($0.paneID)=\($0.reportedCWD ?? "-"):\($0.pathStatus.rawValue)" }
                .joined(separator: ","),
        ].joined(separator: "|")
    }

    public static func renderJSON(_ snapshot: DiagnosticSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
