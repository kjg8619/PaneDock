import Foundation

// `PaneRecord`는 소스 중립 레코드로 옮겼다: `WorkInfoFactory.swift`.
// herdr 전용 DTO 브리지만 이 파일에 남긴다(아래 확장).
extension PaneRecord {
    init(dto: PaneRecordDTO) {
        self.paneID = dto.paneID
        self.workspaceID = dto.workspaceID
        self.tabID = dto.tabID
        self.terminalID = dto.terminalID
        self.cwd = dto.cwd
        self.foregroundCWD = dto.foregroundCWD
        self.focused = dto.focused
        self.revision = dto.revision
        self.title = dto.title
    }
}

/// 부트스트랩 결과. 포커스는 서버가 알려준 값만 신뢰한다.
public struct HerdrBootstrap: Equatable, Sendable {
    public var serverVersion: String?
    public var protocolVersion: Int?
    public var focusedPaneID: String?
    public var focusedTabID: String?
    public var focusedWorkspaceID: String?
    public var panes: [PaneRecord]

    public init(
        serverVersion: String?,
        protocolVersion: Int?,
        focusedPaneID: String?,
        focusedTabID: String?,
        focusedWorkspaceID: String?,
        panes: [PaneRecord]
    ) {
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.focusedPaneID = focusedPaneID
        self.focusedTabID = focusedTabID
        self.focusedWorkspaceID = focusedWorkspaceID
        self.panes = panes
    }

    public var focusedPane: PaneRecord? {
        guard let focusedPaneID else { return nil }
        return panes.first { $0.paneID == focusedPaneID }
    }
}

/// 경로 문자열 정규화.
///
/// 정책: **심볼릭 링크를 해석하지 않는다.** 기획서 §8이 심볼릭 링크·대소문자 정책을
/// 미확정으로 두었으므로, 여기서는 비교용으로 `.`·`..`·중복 슬래시만 정리하고
/// 표시용 원본(`reportedCWD`)은 그대로 보존한다.
public enum PathNormalizer {
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let isAbsolute = path.hasPrefix("/")
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append("..")
                }
            default:
                components.append(String(component))
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }
}

/// herdr 소켓 연동. UI를 모른다.
public struct HerdrAdapter {
    /// 설치본에서 확인한 protocol 값. 다르면 `incompatible`로 표시하고 값을 추측하지 않는다.
    public static let expectedProtocolVersion = 22
    public static let adapterID = "herdr"

    public let client: HerdrSocketClient
    public let hostAppID: String
    public let machineID: String

    public init(client: HerdrSocketClient, hostAppID: String = "ghostty", machineID: String = "local") {
        self.client = client
        self.hostAppID = hostAppID
        self.machineID = machineID
    }

    public func ping() throws -> PingResult {
        try client.request("ping", as: PingResult.self)
    }

    /// 포커스 pane 식별자와 전체 pane 목록을 한 번에 받는다.
    ///
    /// `pane.current`를 쓰지 않는 이유: 그 메서드는 호출자 컨텍스트가 실리면
    /// **호출한 pane**을 돌려준다. 세션 스냅샷의 `focused_pane_id`는 서버가 판단한
    /// 포커스이므로 호출자와 무관하다.
    public func bootstrap() throws -> HerdrBootstrap {
        let result = try client.request("session.snapshot", as: SessionSnapshotResult.self)
        let snapshot = result.snapshot
        return HerdrBootstrap(
            serverVersion: snapshot.version,
            protocolVersion: snapshot.protocolVersion,
            focusedPaneID: snapshot.focusedPaneID,
            focusedTabID: snapshot.focusedTabID,
            focusedWorkspaceID: snapshot.focusedWorkspaceID,
            panes: snapshot.panes.map(PaneRecord.init(dto:))
        )
    }

    /// 대상 pane 하나만 다시 읽는다(응답 690 bytes 수준).
    public func pane(id: String) throws -> PaneRecord {
        let result = try client.request(
            "pane.get",
            params: .object(["pane_id": .string(id)]),
            as: PaneGetResult.self
        )
        return PaneRecord(dto: result.pane)
    }

    /// 이벤트 이름과 pane 식별자만 쓰는 갱신 신호. 실제 값은 다시 조회한다.
    public func subscribe(types: [String]) throws -> HerdrSubscription {
        try client.subscribe(types: types)
    }

    public func isProtocolCompatible(_ reported: Int?) -> Bool {
        reported == nil || reported == Self.expectedProtocolVersion
    }

    public func connectionStatus(for reportedProtocol: Int?) -> ConnectionStatus {
        isProtocolCompatible(reportedProtocol) ? .connected : .incompatible
    }

    /// 공통 변환기. 변환 규칙은 `WorkInfoFactory`에 있고, 여기서는 herdr 식별자와
    /// 기본 경로 출처(`pane.cwd`)만 정한다.
    ///
    /// 이 클래스에 있던 `pendingWorkInfo`/`currentWorkInfo`는 동작 그대로 팩토리로 옮겼다.
    public var factory: WorkInfoFactory {
        WorkInfoFactory(
            adapterID: Self.adapterID,
            hostAppID: hostAppID,
            machineID: machineID,
            defaultCWDSource: .paneCWD
        )
    }
}
