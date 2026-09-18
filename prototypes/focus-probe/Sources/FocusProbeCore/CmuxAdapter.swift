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
        client: CmuxQuerying = CmuxCLIClient(executable: CmuxCLIResolver.resolve()),
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

/// 최전면 앱 판정. 소켓도 AppleScript도 알려주지 않으므로 **OS에서** 읽는다.
///
/// 반환값이 옵셔널인 이유: **판정할 수 없는 실행 문맥이 있다.**
/// WindowServer에 연결되지 않은 프로세스(TTY 없이 분리 실행 등)에서는 값이 nil이 된다.
/// 그때 `false`로 단정하면 "최전면 아님"이라는 **거짓 상태**를 만들어 창이 "유지 중"으로
/// 잘못 표시된다(V11에서 실제로 관측했다).
public protocol FrontmostAppChecking: Sendable {
    /// 최전면 앱의 번들 식별자. **판정할 수 없으면 nil.**
    func frontmostBundleIdentifier() -> String?
}

public extension FrontmostAppChecking {
    /// 최전면이면 true, 아니면 false, **판정할 수 없으면 nil**.
    func isFrontmost(_ bundleIdentifier: String) -> Bool? {
        frontmostBundleIdentifier().map { $0 == bundleIdentifier }
    }
}

/// 조회 실패. 연결 상태 표시로 바로 매핑된다.
public enum CmuxQueryError: Error, Equatable, TerminalHostQueryFailure {
    /// cmux CLI를 찾을 수 없다(설치 위치를 찾지 못했거나 `env`가 실행 파일을 못 찾음).
    case cliNotFound(searched: [String])
    /// CLI는 찾았지만 실행 자체가 실패했다(권한·손상 등).
    case launchFailed(String)
    /// 소켓이 없다 → cmux가 실행 중이 아니다.
    case notRunning
    /// 시간 안에 응답이 없다.
    case timedOut
    /// 응답을 해석할 수 없다.
    case malformed(String)
    /// 소켓 연결이 거부됐다.
    case refused(message: String)
    case failed(status: Int32, message: String)

    public var connectionStatus: ConnectionStatus {
        switch self {
        case .cliNotFound, .launchFailed, .notRunning, .timedOut: return .unavailable
        case .malformed: return .incompatible
        case .refused, .failed: return .refused
        }
    }

    public func diagnosticText(appName: String, requirement: String? = nil) -> String {
        switch self {
        case .cliNotFound(let searched):
            // 찾아본 위치는 **개수와 대표 경로만** 남긴다(환경 전체를 출력하지 않는다).
            let sample = searched.prefix(3).joined(separator: ", ")
            return "\(appName) CLI not found (tried \(searched.count): \(sample))"
        case .launchFailed(let reason): return "\(appName) CLI could not start: \(reason)"
        case .notRunning: return "\(appName) is not running (socket not found)"
        case .timedOut: return "\(appName) did not answer in time"
        case .malformed(let text): return "\(appName) returned an unreadable answer: \(text)"
        case .refused(let message): return "\(appName) refused the connection: \(message)"
        case .failed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "\(appName) query failed (exit \(status))" : trimmed
        }
    }
}

/// cmux CLI 실행 파일을 찾는다.
///
/// GUI 앱은 셸 PATH(`/opt/homebrew/bin` 등)를 물려받지 않으므로 **설치 위치를 직접 찾아본다.**
/// 특정 사용자의 홈브루 경로에 고정하지 않는다 — 아래 후보를 순서대로 확인하고, 없으면 PATH 조회로 넘어간다.
public enum CmuxCLIResolver {
    /// 설치본 후보(존재하는 첫 항목을 쓴다).
    public static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
            "\(home)/.local/bin/cmux",
            "\(home)/bin/cmux",
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "\(home)/Applications/cmux.app/Contents/Resources/bin/cmux",
        ]
    }

    /// 명시적 주입 → 설치본 후보 → PATH 조회(`env`) 순서로 실행 파일을 정한다.
    ///
    /// - Parameter explicit: 호출자가 지정한 경로(진단용 플래그·테스트 주입). 존재하면 그대로 쓴다.
    public static func resolve(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if let explicit, !explicit.isEmpty, isExecutable(explicit) { return explicit }
        // 환경 변수로 지정한 경로도 존중한다(PATH를 못 쓰는 환경을 위한 우회).
        if let override = environment["PANEDOCK_CMUX_CLI"], !override.isEmpty, isExecutable(override) {
            return override
        }
        for candidate in candidates() where isExecutable(candidate) { return candidate }
        // 마지막으로 PATH 조회에 맡긴다(셸에서 실행할 때와 같은 동작).
        return "cmux"
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

    public init(executable: String = CmuxCLIResolver.resolve(), timeout: TimeInterval = 4.0) {
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
    ///
    /// **출력은 파이프가 아니라 임시 파일로 받는다.** cmux CLI는 stdout/stderr가 파이프이면
    /// 응답을 내놓지 않고 멈춘다(실측: 파이프=타임아웃, 파일·`/dev/null`=0.02~0.04초). 같은 실행 파일·인자·
    /// 환경에서도 이 차이만으로 갈리므로, 실행 경계에서 파이프를 쓰지 않는다.
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        if executable.hasPrefix("/") {
            // 설치본·주입 경로를 그대로 실행한다(GUI PATH에 의존하지 않는다).
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            // PATH 조회가 필요할 때만 `env`를 거친다.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_QUIET"] = "1"   // 안내 문구를 stderr에서 줄인다(값은 쓰지 않는다)
        process.environment = environment
        // GUI 앱의 작업 디렉터리(`/`)가 아니라 사용자의 홈에서 실행한다(셸 실행과 같은 조건).
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let directory = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString
        let outURL = directory.appendingPathComponent("cmux-out-\(stamp).txt")
        let errURL = directory.appendingPathComponent("cmux-err-\(stamp).txt")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let outHandle = FileHandle(forWritingAtPath: outURL.path),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            throw CmuxQueryError.launchFailed("임시 출력 파일을 만들 수 없습니다")
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        do {
            try process.run()
        } catch {
            let reason = (error as NSError).localizedDescription
            // 실행 파일이 없으면 "설치본을 찾지 못했다"로 구분한다(일반 실패로 뭉뚱그리지 않는다).
            if (error as NSError).code == NSFileNoSuchFileError
                || (error as NSError).code == ENOENT
                || reason.lowercased().contains("no such file") {
                throw CmuxQueryError.cliNotFound(searched: [executable])
            }
            throw CmuxQueryError.launchFailed(reason)
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

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""

        guard process.terminationStatus == 0 else {
            throw Self.classify(stderr: stderr, status: process.terminationStatus)
        }
        return stdout
    }

    /// CLI 실패를 분류한다. **실행 파일 없음·실행 실패·연결 거부·시간 초과를 서로 다르게** 다룬다.
    public static func classify(stderr: String, status: Int32) -> CmuxQueryError {
        let lowered = stderr.lowercased()
        if status == 127 || lowered.contains("no such file or directory") || lowered.contains("command not found") {
            return .cliNotFound(searched: [])
        }
        if lowered.contains("socket not found") || lowered.contains("not running") || lowered.contains("no live cmux socket") {
            return .notRunning
        }
        if lowered.contains("connection refused") || lowered.contains("refused") {
            return .refused(message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .failed(status: status, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
