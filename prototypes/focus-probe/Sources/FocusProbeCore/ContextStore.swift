import Foundation

/// 관측 하나. 조회를 시작한 시점의 세대를 함께 들고 다닌다.
public struct PaneObservation: Equatable, Sendable {
    public var generation: UInt64
    public var record: PaneRecord
    /// 바깥 앱이 최전면인지. 연동이 제공하지 않으면 nil.
    public var hostFrontmost: Bool?

    public init(generation: UInt64, record: PaneRecord, hostFrontmost: Bool? = nil) {
        self.generation = generation
        self.record = record
        self.hostFrontmost = hostFrontmost
    }
}

public enum StoreOutcome: Equatable {
    /// 표시 묶음을 갱신했다.
    case applied
    /// 늦은 응답이거나 이전 대상의 응답이라 폐기했다.
    case discardedStale
    /// 비활성 pane의 갱신이라 캐시만 바꿨다. 표시 묶음은 그대로다.
    case cachedBackground
}

/// 최신 작업 정보와 캐시를 관리한다. UI를 모른다.
///
/// 표시 규칙:
/// - 새 pane으로 전환하면 그 pane의 경로는 `.pending`이다. 직전 경로를 새 pane의 경로로
///   승격하지 않고 `previous`에 따로 둔다.
/// - 비활성 pane의 갱신은 캐시만 바꾼다.
/// - 연결 실패는 추적 상태와 별개 필드로 남기고, 경로를 추측으로 채우지 않는다.
public final class ContextStore {
    public private(set) var current: CurrentWorkInfo?
    public private(set) var previous: CurrentWorkInfo?
    public private(set) var connection: ConnectionStatus
    public private(set) var lastFailure: String?

    private var cache: [String: CurrentWorkInfo] = [:]
    private let resolver: FocusResolver
    private let validator: PathValidating
    private let factory: WorkInfoFactory
    private let clock: () -> Date

    public init(
        factory: WorkInfoFactory,
        resolver: FocusResolver,
        validator: PathValidating,
        initialConnection: ConnectionStatus = .unavailable,
        clock: @escaping () -> Date = Date.init
    ) {
        self.factory = factory
        self.resolver = resolver
        self.validator = validator
        self.connection = initialConnection
        self.clock = clock
    }

    public var focusGeneration: UInt64 { resolver.generation }
    public var targetPaneID: String? { resolver.targetPaneID }
    public var cachedPaneCount: Int { cache.count }

    public func cached(_ paneID: String) -> CurrentWorkInfo? { cache[paneID] }

    public func noteConnection(_ status: ConnectionStatus) {
        connection = status
        if status == .connected { lastFailure = nil }
        if current != nil { current?.connectionStatus = status }
    }

    public func noteFailure(_ text: String) {
        lastFailure = text
    }

    /// 실제 포커스 pane으로 대상을 맞춘다.
    ///
    /// 이전 경로는 `previous`로만 옮기고, 새 대상의 경로 슬롯은 비워 둔다(`.pending`).
    public func alignTarget(to record: PaneRecord) {
        if current?.identity.paneID == record.paneID {
            // 같은 pane이면 표시 묶음을 건드리지 않는다. 경로 갱신은 apply가 담당한다.
            return
        }
        if let existing = current {
            previous = existing
        }
        let generation = resolver.setTarget(record.paneID)
        current = factory.pendingWorkInfo(
            for: record,
            generation: generation,
            connection: connection,
            observedAt: clock()
        )
    }

    /// 관측을 반영한다.
    public func apply(_ observation: PaneObservation) -> StoreOutcome {
        guard observation.generation == resolver.generation else {
            return .discardedStale
        }
        guard observation.record.paneID == resolver.targetPaneID else {
            // 비활성 pane의 갱신. 캐시만 갱신하고 표시 묶음은 건드리지 않는다.
            cache[observation.record.paneID] = factory.currentWorkInfo(
                from: observation.record,
                generation: observation.generation,
                connection: connection,
                observedAt: clock(),
                validator: validator,
                hostFrontmost: observation.hostFrontmost
            )
            return .cachedBackground
        }

        cache[observation.record.paneID] = factory.currentWorkInfo(
            from: observation.record,
            generation: observation.generation,
            connection: connection,
            observedAt: clock(),
            validator: validator,
            hostFrontmost: observation.hostFrontmost
        )
        current = factory.currentWorkInfo(
            from: observation.record,
            generation: observation.generation,
            connection: connection,
            observedAt: clock(),
            validator: validator,
            hostFrontmost: observation.hostFrontmost
        )
        return .applied
    }

    /// 연결 이상. 표시 묶음은 남기되 유효성을 낮춘다.
    public func markConnectionLost(_ status: ConnectionStatus, reason: String) {
        connection = status
        lastFailure = reason
        if var info = current {
            info.connectionStatus = status
            info.focusStatus = .unknown
            current = info
        }
    }

    /// 연결 재수립. 세대를 올려 이전 연결의 응답을 무효화한다.
    public func markReconnected() {
        resolver.invalidateForReconnect()
        noteConnection(.connected)
    }

    /// 포커스는 확인됐지만 **그 대상의 정보를 만들 수 없을 때**(예: 터미널이 아닌 패널).
    ///
    /// 이전 대상을 현재 대상처럼 남기지 않는다. 이전 값은 `previous`로만 옮기고,
    /// 표시 묶음은 "확인 중"(`unresolved`)으로 되돌린다. 경로를 추측으로 채우지 않는다.
    /// `lastFailure`에 사유가 있으면 화면의 detail 줄에 그대로 드러난다.
    public func markTargetUnknown() {
        guard let existing = current else { return }
        previous = existing
        resolver.clearTarget()
        current = factory.unresolvedWorkInfo(generation: resolver.generation, connection: connection)
    }
}
