import Foundation

/// cmux 소켓 연동 (**실험 경로**).
///
/// ## 왜 AppleScript가 아니라 소켓인가 — 둘 다 설치본에서 직접 확인했다
///
/// cmux는 AppleScript 사전(`cmux.sdef`)을 포함하고 `NSAppleScriptEnabled=true`다.
/// 그런데 **객체 모델이 응답하지 않는다**(V11 실측):

///
/// | AppleScript | 결과 |
/// | --- | --- |
/// | `version`, `frontmost` | 즉시 응답 |
/// | `count of windows`, `id of front window` | **6초 타임아웃(응답 없음)** |
/// | `count of terminals`, `working directory of terminal 1` | **6초 타임아웃(응답 없음)** |
///
/// 즉 창·workspace·panel·경로를 AppleScript로 **읽을 수 없다.** 반면 소켓은 동작한다.
///
/// ## 접근 모드
///
/// 이 기기의 `socketControlMode`는 **`automation`**이다(Settings > Automation,
/// 공식 스키마 `cmux.schema.json`의 enum 값). **설정을 바꾸지 않았고 우회하지도 않았다.**
/// 소켓 경로를 강제로 열지 않고, 이미 허용된 공식 경로를 그대로 쓴다.
///
/// ## 읽는 것 — 읽기 명령만
///
/// - `cmux identify --json --id-format uuids`
///   → 선택된 창·workspace·pane·surface **식별자**, `surface_type`, `is_browser_surface`, `caller`
/// - `cmux sidebar-state --workspace <workspace id>`
///   → `cwd`(workspace **요약**), `focused_cwd`, `focused_panel`
///
/// **하지 않는 것:** workspace·pane·surface 생성/이동/포커스 변경, 입력 전송,
/// `select-workspace`, `focus-*`, 앱 활성화. 조회에 쓰는 명령은 위 두 개뿐이다.
///
/// ## 경로를 추측하지 않기 위한 두 규칙
///
/// 1. **workspace 요약 `cwd`를 surface의 경로로 쓰지 않는다.** 경로는 `focused_cwd`에서만 온다.
/// 2. `focused_cwd`는 `focused_panel`이 **선택된 surface와 같을 때만** 그 surface의 경로로 인정한다.
///    다르면 경로를 모르는 것으로 표시한다(`unsupported`). 추측으로 채우지 않는다.
///
/// ## 이 Adapter가 제공하지 않는 것
///
/// 소켓은 **포커스된 panel의 경로만** 준다. 비활성 panel의 경로를 읽는 공식 방법은
/// 확인하지 못했으므로, 비활성 영역의 경로 변경은 애초에 관측되지 않는다
/// (요구사항 C는 구조적으로 성립한다 — 표시가 바뀔 수 없다).
/// 앱 최전면 여부도 소켓이 알려주지 않아 **OS에서** 읽는다(`FrontmostAppChecking`).
public struct CmuxAdapter: TerminalHostAdapter {
    public static let adapterID = "cmux"
    /// cmux 앱의 번들 식별자. 최전면 판정에만 쓴다.
    public static let bundleIdentifier = "com.cmuxterm.app"

    public let appName = "cmux"
    /// 소켓 프로토콜 버전을 **요구사항으로 주장하지 않는다.** 설치본에서 확인한 값은 2다.
    public var appleScriptRequirement: String? { nil }

    public let hostAppID: String
    public let machineID: String
    private let client: CmuxQuerying
    private let frontmost: FrontmostAppChecking

    public init(
        client: CmuxQuerying = CmuxCLIClient(),
        frontmost: FrontmostAppChecking = WorkspaceFrontmostAppChecker(),
        hostAppID: String = "cmux",
        machineID: String = "local"
    ) {
        self.client = client
        self.frontmost = frontmost
        self.hostAppID = hostAppID
        self.machineID = machineID
    }

    public var factory: WorkInfoFactory {
        WorkInfoFactory(
            adapterID: Self.adapterID,
            hostAppID: hostAppID,
            machineID: machineID,
            defaultCWDSource: .cmuxFocusedCWD
        )
    }

    /// 한 번 조회해 공통 스키마로 옮긴다. **AppleScript 조회와 같은 스냅샷 타입을 쓴다** —
    /// 그래야 반영·표시 코드가 두 경로에서 하나로 유지된다.
    public func snapshot() throws -> TerminalHostSnapshot {
        let identified = try client.identify()
        guard let focused = identified.focused else {
            // 창이 없다. 연결은 정상이고 대상만 없다.
            throw TerminalHostQueryError.noWindow
        }

        let sidebar = try client.sidebarState(workspaceID: focused.workspaceID)

        // 규칙 2: focused_panel이 선택된 surface와 같을 때만 그 경로를 인정한다.
        let panelMatches = sidebar.focusedPanel == focused.surfaceID
        // 규칙 1: workspace 요약 cwd는 쓰지 않는다. 경로는 focused_cwd에서만 온다.
        let path = panelMatches ? sidebar.focusedCWD : nil

        let isTerminal = !focused.isBrowserSurface && focused.surfaceType == "terminal"
        let terminals: [TerminalHostTerminal] = isTerminal
            ? [
                TerminalHostTerminal(
                    terminalID: focused.surfaceID,
                    windowID: focused.windowID,
                    // 공통 스키마는 window → tab → terminal 3단계다.
                    // cmux는 window → workspace → pane → surface 4단계이므로 **workspace를 tab 슬롯**에 넣는다
                    // (cmux에서도 workspace가 창 안의 탭 역할을 한다). cmux의 `pane_id`(분할 컨테이너)와
                    // 별도 `tab_id`는 이 최소 진단에서 표시하지 않는다.
                    tabID: focused.workspaceID,
                    workingDirectory: path,
                    name: nil
                )
            ]
            : []

        return TerminalHostSnapshot(
            version: nil,
            frontmost: frontmost.isFrontmost(Self.bundleIdentifier),
            frontWindowID: focused.windowID,
            selectedTabID: focused.workspaceID,
            focusedTerminalID: focused.surfaceID,
            focusedWorkingDirectory: path,
            focusedPanelIsTerminal: isTerminal,
            terminals: terminals
        )
    }

    /// 포커스된 surface를 레코드로 만든다.
    ///
    /// 사전의 `tab`은 workspace, `pane`은 분할 컨테이너, `surface`는 panel이다.
    /// 표시 대상은 **선택된 surface**이므로 `paneID`에 surface 식별자를 쓴다.
    public func focusedRecord(in snapshot: TerminalHostSnapshot) -> PaneRecord? {
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

    /// 비활성 panel의 경로를 읽는 공식 방법을 확인하지 못했으므로 배경 관측은 비어 있다.
    public func records(in snapshot: TerminalHostSnapshot) -> [PaneRecord] {
        []
    }

    /// 대상이 없을 때의 사유. **"터미널이 아닌 panel"과 "대상 없음"을 구분한다.**
    public func noTargetReason(in snapshot: TerminalHostSnapshot) -> String {
        if snapshot.focusedPanelIsTerminal == false {
            return "focused cmux panel is not a terminal (no path is reported for it)"
        }
        return "no focused terminal reported by cmux"
    }

    /// 버전 게이트 없음. 소켓 프로토콜 버전을 요구사항으로 주장하지 않는다.
    public func unsupportedVersionReason(_ version: String?) -> String? { nil }
}

// MARK: - 조회 경계

/// cmux 조회를 주입 가능하게 분리한다. 자체 검사가 합성 JSON으로 파싱을 검증할 수 있다.
public protocol CmuxQuerying: Sendable {
    func identify() throws -> CmuxIdentify
    func sidebarState(workspaceID: String) throws -> CmuxSidebarState
}

/// 최전면 앱 판정. 소켓이 알려주지 않으므로 **OS에서** 읽는다.
public protocol FrontmostAppChecking: Sendable {
    func isFrontmost(_ bundleIdentifier: String) -> Bool
}

/// 조회 실패. 연결 상태 표시로 바로 매핑된다.
public enum CmuxQueryError: Error, Equatable, TerminalHostQueryFailure {
    /// cmux CLI를 찾을 수 없다.
    case cliUnavailable
    /// 소켓이 없다 → cmux가 실행 중이 아니다.
    case notRunning
    /// 시간 안에 응답이 없다.
    case timedOut
    /// 응답을 해석할 수 없다.
    case malformed(String)
    case failed(status: Int32, message: String)

    public var connectionStatus: ConnectionStatus {
        switch self {
        case .cliUnavailable: return .unavailable
        case .notRunning: return .unavailable
        case .timedOut: return .unavailable
        case .malformed: return .incompatible
        case .failed: return .refused
        }
    }

    public func diagnosticText(appName: String, requirement: String? = nil) -> String {
        switch self {
        case .cliUnavailable: return "\(appName) CLI not found"
        case .notRunning: return "\(appName) is not running (socket not found)"
        case .timedOut: return "\(appName) did not answer in time"
        case .malformed(let text): return "\(appName) returned an unreadable answer: \(text)"
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(appName) query failed (exit \(status))" : trimmed
        }
    }
}

// MARK: - 조회 결과

/// `cmux identify --json --id-format uuids`의 결과.
public struct CmuxIdentify: Equatable, Sendable {
    /// 호출한 쪽의 컨텍스트. **진단 목표가 아니다**(바깥 프로세스에서는 보통 nil).
    public var caller: String?
    public var focused: CmuxFocused?

    public init(caller: String?, focused: CmuxFocused?) {
        self.caller = caller
        self.focused = focused
    }

    public static func parse(_ data: Data) throws -> CmuxIdentify {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CmuxQueryError.malformed("identify: JSON 객체가 아님")
        }
        let caller = root["caller"] as? String
        let focusedObject = root["focused"] as? [String: Any]
        return CmuxIdentify(caller: caller, focused: focusedObject.flatMap(CmuxFocused.init(json:)))
    }
}

/// 선택된 대상의 식별자. cmux의 `window`/`workspace`/`pane`/`surface`를 그대로 보존한다.
public struct CmuxFocused: Equatable, Sendable {
    public var windowID: String
    public var workspaceID: String
    public var paneID: String
    public var surfaceID: String
    public var tabID: String
    /// `terminal`, `browser`, … (cmux가 보고한 값 그대로)
    public var surfaceType: String
    public var isBrowserSurface: Bool

    public init(
        windowID: String,
        workspaceID: String,
        paneID: String,
        surfaceID: String,
        tabID: String,
        surfaceType: String,
        isBrowserSurface: Bool
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.tabID = tabID
        self.surfaceType = surfaceType
        self.isBrowserSurface = isBrowserSurface
    }

    init?(json: [String: Any]) {
        guard let windowID = json["window_id"] as? String,
              let workspaceID = json["workspace_id"] as? String,
              let paneID = json["pane_id"] as? String,
              let surfaceID = json["surface_id"] as? String
        else { return nil }
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.tabID = json["tab_id"] as? String ?? surfaceID
        self.surfaceType = json["surface_type"] as? String ?? "unknown"
        self.isBrowserSurface = json["is_browser_surface"] as? Bool ?? false
    }
}

/// `cmux sidebar-state`의 결과.
///
/// `cwd`는 **workspace 요약**이고 `focusedCWD`는 포커스된 panel의 경로다.
/// 둘을 하나로 합치지 않는다. `focusedPanel`은 그 경로가 어느 panel의 것인지 알려준다.
public struct CmuxSidebarState: Equatable, Sendable {
    public var cwd: String?
    public var focusedCWD: String?
    public var focusedPanel: String?

    public init(cwd: String?, focusedCWD: String?, focusedPanel: String?) {
        self.cwd = cwd
        self.focusedCWD = focusedCWD
        self.focusedPanel = focusedPanel
    }

    public static func parse(_ output: String) -> CmuxSidebarState {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            values[key] = String(line[line.index(after: separator)...])
        }
        func value(_ key: String) -> String? {
            guard let raw = values[key], !raw.isEmpty, raw != "none" else { return nil }
            return raw
        }
        return CmuxSidebarState(
            cwd: value("cwd"),
            focusedCWD: value("focused_cwd"),
            focusedPanel: value("focused_panel")
        )
    }
}

// MARK: - 실제 조회

/// `cmux` CLI를 실행해 조회한다.
///
/// 소켓을 직접 열지 않고 **공식 CLI**를 쓴다("Every command is available through both
/// interfaces" — 공식 문서). 프로세스 경계가 있어 승인 주체도 바뀌지 않는다.
/// **읽기 명령만 실행한다**(`identify`, `sidebar-state`).
public struct CmuxCLIClient: CmuxQuerying {
    public let executable: String
    public let timeout: TimeInterval

    public init(executable: String = "cmux", timeout: TimeInterval = 4.0) {
        self.executable = executable
        self.timeout = timeout
    }

    public func identify() throws -> CmuxIdentify {
        let output = try run(["identify", "--json", "--id-format", "uuids"])
        return try CmuxIdentify.parse(Data(output.utf8))
    }

    public func sidebarState(workspaceID: String) throws -> CmuxSidebarState {
        // workspace를 **명시**한다. 호출자 컨텍스트에 기대지 않는다.
        let output = try run(["sidebar-state", "--workspace", workspaceID])
        return CmuxSidebarState.parse(output)
    }

    /// 읽기 명령 하나를 실행한다. 인자는 배열로 넘겨 셸 해석을 거치지 않는다.
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_QUIET"] = "1"   // 안내 문구를 stderr에서 줄인다(값은 쓰지 않는다)
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CmuxQueryError.cliUnavailable
        }

        // 무한 대기를 피한다. AppleScript가 응답 없이 멈추는 것을 실제로 관측했으므로
        // 외부 프로세스에는 항상 상한을 둔다.
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1.0)
            throw CmuxQueryError.timedOut
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw Self.classify(stderr: stderr, status: process.terminationStatus)
        }
        return stdout
    }

    /// CLI 실패를 분류한다. 소켓이 없으면 "실행 중이 아님"이다.
    static func classify(stderr: String, status: Int32) -> CmuxQueryError {
        let lowered = stderr.lowercased()
        if lowered.contains("socket not found") || lowered.contains("not running") {
            return .notRunning
        }
        return .failed(status: status, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
