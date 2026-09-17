import Foundation

// MARK: - AppleScript 실행

/// AppleScript 실행을 주입 가능하게 분리한다. 자체 검사가 합성 출력으로 파서를 검증할 수 있다.
public protocol AppleScriptRunning: Sendable {
    func run(_ source: String) throws -> String
}

/// `/usr/bin/osascript`로 실행한다.
///
/// `NSAppleScript` 대신 별도 프로세스를 쓰는 이유: 자동화(TCC) 승인이 이미 확인된 경로가
/// `osascript`이고, 프로세스 경계가 있으면 승인 주체가 바뀌지 않는다.
public struct OsaScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GhosttyQueryError.other("osascript 실행 실패: \(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GhosttyQueryError.classify(stderr: stderr, status: process.terminationStatus)
        }
        return stdout
    }
}

// MARK: - 조회 오류

/// Ghostty 조회 실패. 상태 표시로 바로 매핑된다.
public enum GhosttyQueryError: Error, Equatable {
    /// Ghostty가 실행 중이 아니다 (AppleScript -600).
    case notRunning
    /// 자동화 권한 거부 (AppleScript -1743).
    case automationDenied
    /// AppleScript 미지원 — 1.3.0 미만이거나 `macos-applescript = false` (AppleScript -1708/-1700).
    case appleScriptUnsupported
    /// 창이 없다. 연결은 정상이고 대상만 없다 (AppleScript -1728).
    case noWindow
    case other(String)

    public var connectionStatus: ConnectionStatus {
        switch self {
        case .notRunning: return .unavailable
        case .automationDenied: return .denied
        case .appleScriptUnsupported: return .incompatible
        // 창이 없는 것은 연결 문제가 아니다. 대상이 없을 뿐이다.
        case .noWindow: return .connected
        case .other: return .unavailable
        }
    }

    public var diagnosticText: String {
        switch self {
        case .notRunning: return "Ghostty is not running"
        case .automationDenied: return "automation permission denied (-1743)"
        case .appleScriptUnsupported: return "Ghostty AppleScript unavailable (requires 1.3.0+)"
        case .noWindow: return "Ghostty has no window"
        case .other(let text): return text
        }
    }

    /// osascript stderr에서 AppleScript 오류 코드를 꺼내 분류한다.
    public static func classify(stderr: String, status: Int32) -> GhosttyQueryError {
        let code = extractErrorCode(from: stderr)
        switch code {
        case -600: return .notRunning
        case -1743: return .automationDenied
        case -1708, -1700: return .appleScriptUnsupported
        case -1728: return .noWindow
        default:
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .other(trimmed.isEmpty ? "osascript failed (exit \(status))" : trimmed)
        }
    }

    static func extractErrorCode(from stderr: String) -> Int? {
        // 예: "execution error: Ghostty got an error: Application isn’t running. (-600)"
        guard let open = stderr.lastIndex(of: "("), let close = stderr.lastIndex(of: ")"), open < close else {
            return nil
        }
        let inside = stderr[stderr.index(after: open)..<close]
        return Int(inside.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - 조회 결과

/// Ghostty terminal(surface) 하나.
public struct GhosttyTerminal: Equatable, Sendable {
    public var terminalID: String
    public var windowID: String
    public var tabID: String
    public var workingDirectory: String?
    public var name: String?

    public init(terminalID: String, windowID: String, tabID: String, workingDirectory: String?, name: String?) {
        self.terminalID = terminalID
        self.windowID = windowID
        self.tabID = tabID
        self.workingDirectory = workingDirectory
        self.name = name
    }
}

/// 한 번의 조회 결과. 전부 공식 AppleScript에서 나온다.
public struct GhosttySnapshot: Equatable, Sendable {
    public var version: String?
    public var frontmost: Bool?
    public var frontWindowID: String?
    public var selectedTabID: String?
    public var focusedTerminalID: String?
    public var focusedWorkingDirectory: String?
    public var terminals: [GhosttyTerminal]

    public init(
        version: String?,
        frontmost: Bool?,
        frontWindowID: String?,
        selectedTabID: String?,
        focusedTerminalID: String?,
        focusedWorkingDirectory: String?,
        terminals: [GhosttyTerminal]
    ) {
        self.version = version
        self.frontmost = frontmost
        self.frontWindowID = frontWindowID
        self.selectedTabID = selectedTabID
        self.focusedTerminalID = focusedTerminalID
        self.focusedWorkingDirectory = focusedWorkingDirectory
        self.terminals = terminals
    }

    public var focusedTerminal: GhosttyTerminal? {
        guard let focusedTerminalID else { return nil }
        return terminals.first { $0.terminalID == focusedTerminalID }
    }

    /// 최전면 창의 선택된 탭에서 포커스된 terminal. 공식 문서의 예제와 같은 선택 규칙이다.
    public var target: GhosttyTerminal? {
        if let focusedTerminalID,
           let match = terminals.first(where: { $0.terminalID == focusedTerminalID }) {
            return match
        }
        // 스크립트가 focused terminal을 못 준 경우(구버전 등)에는 최전면 창의 탭 정보로만 복원한다.
        guard let frontWindowID else { return nil }
        return terminals.first { $0.windowID == frontWindowID && $0.tabID == selectedTabID }
    }
}

// MARK: - 스냅샷 반영

/// Ghostty 스냅샷을 `ContextStore`에 반영한다.
///
/// 순서가 규칙이다: **대상 확정 → 비활성 terminal 캐시 반영 → 대상 관측 반영**.
/// 대상 전환 시 경로 슬롯이 비워지고(`pending`), 비활성 관측은 캐시만 바꾼다.
/// CLI와 자체 검사가 같은 경로를 쓰도록 여기에 둔다.
public enum GhosttySnapshotApplier {
    public struct Result: Equatable, Sendable {
        public var target: GhosttyTerminal?
        public var background: [BackgroundPaneInfo]

        public init(target: GhosttyTerminal?, background: [BackgroundPaneInfo]) {
            self.target = target
            self.background = background
        }
    }

    @discardableResult
    public static func apply(
        _ snapshot: GhosttySnapshot,
        adapter: GhosttyAdapter,
        store: ContextStore,
        resolver: FocusResolver,
        validator: PathValidating
    ) -> Result {
        guard let target = snapshot.target, let targetRecord = adapter.focusedRecord(in: snapshot) else {
            store.noteFailure("no focused terminal reported by Ghostty")
            return Result(target: nil, background: [])
        }

        store.alignTarget(to: targetRecord)

        var background: [BackgroundPaneInfo] = []
        for other in adapter.records(in: snapshot) where other.paneID != target.terminalID {
            _ = store.apply(PaneObservation(generation: resolver.generation, record: other))
            background.append(
                BackgroundPaneInfo(
                    paneID: other.paneID,
                    title: other.title,
                    reportedCWD: other.cwd,
                    pathStatus: pathStatus(of: other, validator: validator)
                )
            )
        }

        // `frontmost == false`이고 경로가 유효하면 `held`(마지막 위치 유지)가 된다.
        _ = store.apply(
            PaneObservation(
                generation: resolver.generation,
                record: targetRecord,
                hostFrontmost: snapshot.frontmost
            )
        )
        return Result(target: target, background: background)
    }

    public static func pathStatus(of record: PaneRecord, validator: PathValidating) -> PathStatus {
        guard let path = record.cwd, !path.isEmpty else { return .unsupported }
        return validator.isDirectory(path) ? .valid : .missing
    }
}

/// Ghostty 공식 AppleScript 연동.
///
/// 사용하는 것은 공식 scripting dictionary의 속성뿐이다:
/// `frontmost`, `front window`, `selected tab`, `focused terminal`, `working directory`, `version`.
///
/// **하지 않는 것**: 창/탭/터미널 생성, 입력 전송, 포커스 변경, 화면 내용 읽기.
public struct GhosttyAdapter {
    public static let adapterID = "ghostty"
    /// AppleScript 지원 도입 버전(공식 문서). 이보다 낮으면 `incompatible`로 표시한다.
    public static let minimumVersion = "1.3.0"

    public let hostAppID: String
    public let machineID: String
    public let runner: AppleScriptRunning

    public init(runner: AppleScriptRunning = OsaScriptRunner(), hostAppID: String = "ghostty", machineID: String = "local") {
        self.runner = runner
        self.hostAppID = hostAppID
        self.machineID = machineID
    }

    public var factory: WorkInfoFactory {
        WorkInfoFactory(
            adapterID: Self.adapterID,
            hostAppID: hostAppID,
            machineID: machineID,
            defaultCWDSource: .ghosttyWorkingDirectory
        )
    }

    /// 공식 속성만 읽는 스크립트. 값을 쓰거나 창을 만들지 않는다.
    ///
    /// 주의: 변수명 `st`는 AppleScript 예약어라 문법 오류가 난다. `tab`도 Ghostty 사전의
    /// 클래스명과 충돌해 리터럴 "tab"으로 치환되므로 구분자는 `ASCII character 9`를 쓴다.
    public static let queryScript = """
    if application "Ghostty" is running then
      tell application "Ghostty"
        set sep to (ASCII character 9)
        set out to "version=" & (version as text) & linefeed
        set out to out & "frontmost=" & (frontmost as text) & linefeed
        set fw to front window
        set out to out & "frontWindow=" & (id of fw) & linefeed
        set selTab to selected tab of fw
        set out to out & "selectedTab=" & (id of selTab) & linefeed
        set focusTerm to focused terminal of selTab
        set out to out & "focusedTerminal=" & (id of focusTerm) & linefeed
        set out to out & "focusedWD=" & (working directory of focusTerm) & linefeed
        repeat with w in windows
          set wID to id of w
          repeat with t in tabs of w
            set tID to id of t
            repeat with tm in terminals of t
              set out to out & "term=" & wID & sep & tID & sep & (id of tm) & sep & (working directory of tm) & sep & (name of tm) & linefeed
            end repeat
          end repeat
        end repeat
        return out
      end tell
    else
      return "notRunning=true" & linefeed
    end if
    """

    public func snapshot() throws -> GhosttySnapshot {
        let output = try runner.run(Self.queryScript)
        return try Self.parse(output)
    }

    /// 한 번의 조회 결과에서 대상 레코드를 만든다.
    public func focusedRecord(in snapshot: GhosttySnapshot) -> PaneRecord? {
        guard let target = snapshot.target else { return nil }
        return PaneRecord(
            paneID: target.terminalID,
            workspaceID: target.windowID,
            tabID: target.tabID,
            terminalID: target.terminalID,
            cwd: target.workingDirectory,
            foregroundCWD: nil,
            focused: true,
            revision: nil,
            title: target.name
        )
    }

    /// 모든 terminal을 레코드로 만든다. 비활성 pane 관측(시나리오 C)에 쓴다.
    public func records(in snapshot: GhosttySnapshot) -> [PaneRecord] {
        snapshot.terminals.map { terminal in
            PaneRecord(
                paneID: terminal.terminalID,
                workspaceID: terminal.windowID,
                tabID: terminal.tabID,
                terminalID: terminal.terminalID,
                cwd: terminal.workingDirectory,
                foregroundCWD: nil,
                focused: terminal.terminalID == snapshot.focusedTerminalID,
                revision: nil,
                title: terminal.name
            )
        }
    }

    public func isVersionSupported(_ version: String?) -> Bool {
        guard let version else { return true }   // 확인 불가면 막지 않는다(조회 자체가 실패하면 별도 처리)
        return Self.compareVersions(version, Self.minimumVersion) >= 0
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(lhs)
        let right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    // MARK: 파싱

    public static func parse(_ output: String) throws -> GhosttySnapshot {
        var version: String?
        var frontmost: Bool?
        var frontWindowID: String?
        var selectedTabID: String?
        var focusedTerminalID: String?
        var focusedWorkingDirectory: String?
        var terminals: [GhosttyTerminal] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("notRunning=") {
                throw GhosttyQueryError.notRunning
            }
            if line.hasPrefix("term=") {
                let fields = line.dropFirst("term=".count).components(separatedBy: "\t")
                guard fields.count >= 3 else { continue }
                let name = fields.count >= 5 ? fields[4...].joined(separator: "\t") : nil
                let directory = fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil
                terminals.append(
                    GhosttyTerminal(
                        terminalID: fields[2],
                        windowID: fields[0],
                        tabID: fields[1],
                        workingDirectory: directory,
                        name: name
                    )
                )
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "version": version = value.isEmpty ? nil : value
            case "frontmost": frontmost = (value == "true")
            case "frontWindow": frontWindowID = value.isEmpty ? nil : value
            case "selectedTab": selectedTabID = value.isEmpty ? nil : value
            case "focusedTerminal": focusedTerminalID = value.isEmpty ? nil : value
            case "focusedWD": focusedWorkingDirectory = value.isEmpty ? nil : value
            default: break
            }
        }

        guard frontWindowID != nil || !terminals.isEmpty else {
            throw GhosttyQueryError.noWindow
        }

        return GhosttySnapshot(
            version: version,
            frontmost: frontmost,
            frontWindowID: frontWindowID,
            selectedTabID: selectedTabID,
            focusedTerminalID: focusedTerminalID,
            focusedWorkingDirectory: focusedWorkingDirectory,
            terminals: terminals
        )
    }
}
