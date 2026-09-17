import Foundation

/// 경로 출처. 기획서 §7의 `cwdSource`에 대응한다.
///
/// herdr는 pane마다 서로 다른 의미의 경로를 두 개 제공한다(공식 문서 확인).
/// - `pane.cwd`: pane/workspace의 작업 디렉터리(라벨·복원에 쓰이는 값)
/// - `pane.foreground_cwd`: 현재 pane의 PTY를 점유한 프로세스의 cwd
///
/// 두 값은 TUI/에이전트가 PTY를 점유하면 달라질 수 있으므로 하나로 합치지 않는다.
public enum CWDSource: String, Codable, Sendable, CaseIterable {
    /// Ghostty AppleScript `working directory`. terminal(surface)의 live pwd.
    case ghosttyWorkingDirectory = "ghostty:terminal.workingDirectory"
    /// cmux `sidebar-state`의 `focused_cwd`. **포커스된 panel의 경로**다.
    ///
    /// 같은 응답의 `cwd`는 **workspace 요약**이므로 쓰지 않는다.
    /// 두 값을 합치지 않는 이유: 요약 경로를 선택된 panel의 경로로 표시하면
    /// 사용자가 보는 위치와 실제 pane의 위치가 달라진다.
    case cmuxFocusedCWD = "cmux:sidebar-state.focused_cwd"
    case paneCWD = "herdr:pane.cwd"
    case foregroundCWD = "herdr:pane.foreground_cwd"
}

/// 포커스 확인 상태. "아직 모름"과 "이전 위치 유지"를 구분한다.
public enum FocusStatus: String, Codable, Sendable {
    /// 유효한 포커스와 경로를 확인했다.
    case tracked
    /// 새 대상으로 전환했으나 아직 그 대상의 경로를 받지 못했다.
    case pending
    /// 이전 위치를 유지해서 표시하는 중이다.
    case held
    /// 포커스를 확인할 수 없다.
    case unknown
}

/// 경로 유효성. 조회 실패와 "경로 없음"과 "미지원"을 구분한다.
public enum PathStatus: String, Codable, Sendable {
    case valid
    /// 아직 결과를 받지 못했다.
    case pending
    /// 경로는 보고됐지만 파일 시스템에 없다.
    case missing
    /// 연동이 경로를 제공하지 않는다.
    case unsupported
}

/// 연결 상태. 추적 상태와 별개 필드로 유지한다(기획서 §5).
public enum ConnectionStatus: String, Codable, Sendable {
    case connected
    /// 소켓이 없거나 서버가 없다.
    case unavailable
    case refused
    /// 권한 거부.
    case denied
    /// protocol 불일치.
    case incompatible
}

/// 기획서 §7 "식별" 묶음. 원본 식별자를 보존한다.
public struct PaneIdentity: Codable, Equatable, Sendable {
    public var adapterID: String
    public var hostAppID: String
    public var machineID: String
    public var workspaceID: String
    public var tabID: String
    public var paneID: String
    public var terminalID: String?

    public init(
        adapterID: String,
        hostAppID: String,
        machineID: String,
        workspaceID: String,
        tabID: String,
        paneID: String,
        terminalID: String?
    ) {
        self.adapterID = adapterID
        self.hostAppID = hostAppID
        self.machineID = machineID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.terminalID = terminalID
    }
}

/// 현재 작업 정보. 기획서 §7의 최소 필드 묶음을 그대로 따른다.
public struct CurrentWorkInfo: Codable, Equatable, Sendable {
    // 식별
    public var identity: PaneIdentity
    // 경로
    public var reportedCWD: String?
    public var normalizedCWD: String?
    public var cwdSource: CWDSource?
    public var foregroundCWD: String?
    // 신선도·순서
    public var observedAt: Date?
    public var focusGeneration: UInt64
    public var sourceRevision: Int?
    // 유효성
    public var focusStatus: FocusStatus
    public var pathStatus: PathStatus
    public var connectionStatus: ConnectionStatus
    // 표시 보조
    public var title: String?
    /// 바깥 터미널 앱이 최전면인지. `nil`은 확인 불가(연동이 제공하지 않음).
    /// false이고 경로가 유효하면 `focusStatus == .held`(마지막 위치 유지)가 된다.
    public var hostFrontmost: Bool?

    public init(
        identity: PaneIdentity,
        reportedCWD: String? = nil,
        normalizedCWD: String? = nil,
        cwdSource: CWDSource? = nil,
        foregroundCWD: String? = nil,
        observedAt: Date? = nil,
        focusGeneration: UInt64,
        sourceRevision: Int? = nil,
        focusStatus: FocusStatus,
        pathStatus: PathStatus,
        connectionStatus: ConnectionStatus,
        title: String? = nil,
        hostFrontmost: Bool? = nil
    ) {
        self.identity = identity
        self.reportedCWD = reportedCWD
        self.normalizedCWD = normalizedCWD
        self.cwdSource = cwdSource
        self.foregroundCWD = foregroundCWD
        self.observedAt = observedAt
        self.focusGeneration = focusGeneration
        self.sourceRevision = sourceRevision
        self.focusStatus = focusStatus
        self.pathStatus = pathStatus
        self.connectionStatus = connectionStatus
        self.title = title
        self.hostFrontmost = hostFrontmost
    }
}

/// 경로 존재 확인을 주입 가능하게 분리한다. 자체 검사를 결정적으로 만들기 위한 것이다.
public protocol PathValidating: Sendable {
    func isDirectory(_ path: String) -> Bool
}

public struct FileSystemPathValidator: PathValidating {
    public init() {}
    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

/// 진단 출력 한 묶음.
public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public var current: CurrentWorkInfo
    /// 직전에 표시했던 위치. "이전 위치"로만 표시하며 새 pane의 경로로 승격하지 않는다.
    public var previous: CurrentWorkInfo?
    public var cachedPaneCount: Int
    public var serverVersion: String?
    public var protocolVersion: Int?
    public var expectedProtocolVersion: Int
    public var socketPath: String
    /// `--caller` 옵션에서만 채운다. 기본 진단의 목표 pane이 아니다.
    public var callerPaneID: String?
    /// 바깥 앱 버전(예: Ghostty 1.3.1).
    public var hostVersion: String?
    /// 대상이 아닌 pane의 최근 보고. 시나리오 C(비활성 pane 갱신)를 눈으로 확인하기 위한 표시 전용이다.
    public var backgroundPanes: [BackgroundPaneInfo]

    public init(
        current: CurrentWorkInfo,
        previous: CurrentWorkInfo?,
        cachedPaneCount: Int,
        serverVersion: String?,
        protocolVersion: Int?,
        expectedProtocolVersion: Int,
        socketPath: String,
        callerPaneID: String?,
        hostVersion: String? = nil,
        backgroundPanes: [BackgroundPaneInfo] = []
    ) {
        self.current = current
        self.previous = previous
        self.cachedPaneCount = cachedPaneCount
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.expectedProtocolVersion = expectedProtocolVersion
        self.socketPath = socketPath
        self.callerPaneID = callerPaneID
        self.hostVersion = hostVersion
        self.backgroundPanes = backgroundPanes
    }
}

/// 대상이 아닌 pane의 최근 보고.
///
/// 표시 묶음에는 영향을 주지 않는다. "비활성 pane이 갱신되어도 현재 대상이 바뀌지 않는다"를
/// 출력에서 직접 확인할 수 있게 하려고 별도로 담는다.
public struct BackgroundPaneInfo: Codable, Equatable, Sendable {
    public var paneID: String
    public var title: String?
    public var reportedCWD: String?
    public var pathStatus: PathStatus

    public init(paneID: String, title: String?, reportedCWD: String?, pathStatus: PathStatus) {
        self.paneID = paneID
        self.title = title
        self.reportedCWD = reportedCWD
        self.pathStatus = pathStatus
    }
}
