import Foundation

/// 진단용 상태 로그.
///
/// 화면을 읽지 않고도 앱이 실제로 조회하고 상태를 갱신하는지 확인하기 위한 것이다.
/// `--state-log <path>`를 준 경우에만 동작한다.
final class StateLog {
    private let path: String
    private let formatter: ISO8601DateFormatter

    init(path: String) {
        self.path = path
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        self.formatter = formatter
        try? FileManager.default.removeItem(atPath: path)
    }

    func append(refresh: Int, display: String, folderName: String, fullPath: String, paneID: String, locked: Bool, project: String) {
        write("\(formatter.string(from: Date())) refresh=\(refresh) display=\(display) folder=\(folderName) path=\(fullPath) pane=\(paneID) locked=\(locked) project=\(project)")
    }

    /// 상태 갱신이 아닌 사건(호출·닫기·포커스 이동·실행)을 남긴다.
    /// 화면을 읽지 않고도 "무엇이 일어났는지"를 확인하기 위한 것이다.
    func appendEvent(_ text: String) {
        write("\(formatter.string(from: Date())) EVENT \(text)")
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
