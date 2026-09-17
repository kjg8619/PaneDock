import Foundation

/// 소스 중립적인 pane 레코드. Adapter가 이것을 만들어 `ContextStore`에 넘긴다.
///
/// - herdr: `pane.cwd`/`foreground_cwd`/`revision`/`agent`까지 채운다.
/// - ghostty: AppleScript가 주는 것만 채운다(`working directory`, terminal id). `foregroundCWD`,
///   `revision`은 제공되지 않으므로 `nil`이다.
public struct PaneRecord: Equatable, Sendable {
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var terminalID: String?
    public var cwd: String?
    public var foregroundCWD: String?
    public var focused: Bool
    public var revision: Int?
    public var title: String?

    public init(
        paneID: String,
        workspaceID: String,
        tabID: String,
        terminalID: String?,
        cwd: String?,
        foregroundCWD: String?,
        focused: Bool,
        revision: Int?,
        title: String?
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.terminalID = terminalID
        self.cwd = cwd
        self.foregroundCWD = foregroundCWD
        self.focused = focused
        self.revision = revision
        self.title = title
    }
}

/// `PaneRecord` → `CurrentWorkInfo` 변환. Adapter마다 다른 것은 식별자와 기본 경로 출처뿐이라
/// 변환 규칙은 공통으로 둔다.
///
/// 경로 판정 규칙(모든 Adapter 공통):
/// - 보고된 경로가 비어 있으면 `.unsupported`(연동이 경로를 제공하지 않음).
/// - 경로가 있으나 디렉터리가 아니면 `.missing`.
/// - 관측 전 새 대상은 `pendingWorkInfo`로 만들어 경로 슬롯을 비워 둔다.
public struct WorkInfoFactory: Sendable {
    public var adapterID: String
    public var hostAppID: String
    public var machineID: String
    /// 이 Adapter가 기본으로 쓰는 경로 출처. 표시에 그대로 노출된다.
    public var defaultCWDSource: CWDSource

    public init(adapterID: String, hostAppID: String, machineID: String, defaultCWDSource: CWDSource) {
        self.adapterID = adapterID
        self.hostAppID = hostAppID
        self.machineID = machineID
        self.defaultCWDSource = defaultCWDSource
    }

    /// 새 대상이 선택됐지만 아직 그 pane을 관측하지 않은 상태.
    ///
    /// 경로 슬롯을 비워 두는 것이 핵심이다. 직전 경로를 여기에 채우면
    /// 새 pane의 경로인 것처럼 표시된다.
    public func pendingWorkInfo(
        for record: PaneRecord,
        generation: UInt64,
        connection: ConnectionStatus,
        observedAt: Date,
        hostFrontmost: Bool? = nil
    ) -> CurrentWorkInfo {
        CurrentWorkInfo(
            identity: identity(for: record),
            reportedCWD: nil,
            normalizedCWD: nil,
            cwdSource: nil,
            foregroundCWD: nil,
            observedAt: observedAt,
            focusGeneration: generation,
            sourceRevision: record.revision,
            focusStatus: .pending,
            pathStatus: .pending,
            connectionStatus: connection,
            title: record.title,
            hostFrontmost: hostFrontmost
        )
    }

    /// pane 레코드를 현재 작업 정보로 변환한다.
    public func currentWorkInfo(
        from record: PaneRecord,
        generation: UInt64,
        connection: ConnectionStatus,
        observedAt: Date,
        validator: PathValidating,
        hostFrontmost: Bool? = nil
    ) -> CurrentWorkInfo {
        let reported = record.cwd
        let pathStatus: PathStatus
        if let reported, !reported.isEmpty {
            pathStatus = validator.isDirectory(reported) ? .valid : .missing
        } else {
            pathStatus = .unsupported
        }

        let focusStatus: FocusStatus
        switch pathStatus {
        case .valid:
            // 경로가 유효해도 **포커스가 확인된 것과는 다르다.**
            // - 최전면이면 `tracked`: 지금 보고 있는 대상이다.
            // - 최전면이 아니면 `held`: 마지막 위치를 유지해 표시 중이다(기획서 §5).
            // - **판정할 수 없으면 `unknown`**: 후보를 골랐을 뿐, 사용자가 보고 있는 대상을
            //   확인한 것이 아니다. `tracked`로 승격하면 확인하지 않은 포커스를 확인한 것처럼
            //   표시하게 된다(V13에서 고친 결함).
            switch hostFrontmost {
            case .some(true): focusStatus = .tracked
            case .some(false): focusStatus = .held
            case .none: focusStatus = .unknown
            }
        case .pending:
            focusStatus = .pending
        case .missing, .unsupported:
            focusStatus = .unknown
        }

        return CurrentWorkInfo(
            identity: identity(for: record),
            reportedCWD: reported,
            normalizedCWD: reported.map(PathNormalizer.normalize),
            cwdSource: (reported?.isEmpty == false) ? defaultCWDSource : nil,
            foregroundCWD: record.foregroundCWD,
            observedAt: observedAt,
            focusGeneration: generation,
            sourceRevision: record.revision,
            focusStatus: focusStatus,
            pathStatus: pathStatus,
            connectionStatus: connection,
            title: record.title,
            hostFrontmost: hostFrontmost
        )
    }

    /// 아직 대상을 확인하지 못한 상태의 자리 표시자. 경로를 추측으로 채우지 않는다.
    public func unresolvedWorkInfo(generation: UInt64, connection: ConnectionStatus) -> CurrentWorkInfo {
        CurrentWorkInfo(
            identity: PaneIdentity(
                adapterID: adapterID,
                hostAppID: hostAppID,
                machineID: machineID,
                workspaceID: "-",
                tabID: "-",
                paneID: "-",
                terminalID: nil
            ),
            focusGeneration: generation,
            focusStatus: .unknown,
            pathStatus: .pending,
            connectionStatus: connection
        )
    }

    private func identity(for record: PaneRecord) -> PaneIdentity {
        PaneIdentity(
            adapterID: adapterID,
            hostAppID: hostAppID,
            machineID: machineID,
            workspaceID: record.workspaceID,
            tabID: record.tabID,
            paneID: record.paneID,
            terminalID: record.terminalID
        )
    }
}
