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
    /// 지금 표시 중인 대상이 나온 Adapter. 출처가 바뀌면 같은 pane ID라도 다른 대상으로 본다.
    private var currentSourceID: String?
    /// 지금 표시 중인 대상이 **포커스 확인(true)** 관측을 한 번이라도 받았는지.
    ///
    /// 판정 불가(nil)만 받은 대상은 "마지막으로 확인한 대상"이 아니라 **조회 후보**다.
    /// 그 구분 없이 경로만으로 실행을 허용하면, 확인한 적 없는 경로를 현재 작업처럼 실행하게 된다(V14).
    public private(set) var hasConfirmedCurrentTarget = false
    private let resolver: FocusResolver
    private let validator: PathValidating
    private var factory: WorkInfoFactory
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

    /// 표시 묶음 변환에 쓸 factory를 바꾼다.
    ///
    /// **관측을 만든 Adapter의 factory로 맞춘다.** 라우터가 호스트를 바꾸면
    /// 신원(`adapterID`·`hostAppID`)과 경로 출처도 함께 바뀌어야 한다.
    /// 다른 호스트의 레코드를 이 factory로 변환하면 **없는 신원을 만들어내게 된다.**
    public func useFactory(_ factory: WorkInfoFactory) {
        self.factory = factory
    }

    /// 실제 포커스 pane으로 대상을 맞춘다.
    ///
    /// 이전 경로는 `previous`로만 옮기고, 새 대상의 경로 슬롯은 비워 둔다(`.pending`).
    ///
    /// `sourceID`는 이 레코드를 만든 Adapter다. **pane ID가 같아도 출처가 다르면 다른 대상이다** —
    /// 두 Adapter가 같은 형태의 식별자를 쓸 수 있으므로, 출처가 바뀌면 세대를 올려
    /// 이전 출처의 늦은 응답이 새 대상을 덮어쓰지 못하게 한다.
    public func alignTarget(to record: PaneRecord, sourceID: String? = nil) {
        let sourceChanged = currentSourceID != sourceID
        if current?.identity.paneID == record.paneID, !sourceChanged {
            // 같은 pane이면 표시 묶음을 건드리지 않는다. 경로 갱신은 apply가 담당한다.
            return
        }
        if let existing = current {
            previous = existing
        }
        if sourceChanged, current != nil {
            resolver.invalidateForSourceChange()
        }
        currentSourceID = sourceID
        // 대상이 바뀌면 "확인된 적 있음"도 처음으로 되돌린다.
        hasConfirmedCurrentTarget = false
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
        // 현재 대상이 **포커스 확인**을 받았으면 "확인된 대상"이 된다.
        // 판정 불가(nil)만 받은 대상은 여기서 확인되지 않는다 — 조회 후보일 뿐이다.
        if observation.hostFrontmost == true {
            hasConfirmedCurrentTarget = true
        }
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
        // 대상이 사라졌으므로 "확인된 대상"도 아니다.
        hasConfirmedCurrentTarget = false
        current = factory.unresolvedWorkInfo(generation: resolver.generation, connection: connection)
    }
}
