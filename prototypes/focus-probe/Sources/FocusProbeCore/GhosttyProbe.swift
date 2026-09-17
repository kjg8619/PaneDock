import Foundation

/// Ghostty 조회 → 상태 반영 → 진단 묶음 생성.
///
/// CLI와 GUI가 **같은 코드**를 쓴다. UI가 별도 추적 로직을 갖지 않는다.
///
/// **동시성 계약:** 이 클래스는 스레드 안전하지 않다. 호출자가 **하나의 직렬 큐에 가둬서**
/// 접근해야 한다. GUI는 `pane-dock.probe` 큐에서만 만지고 결과 값만 메인으로 넘긴다.
/// 그 계약 때문에 `@unchecked Sendable`로 선언한다.
public final class GhosttyProbe: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case startup
        case unchanged
        case changed
    }

    public let adapter: GhosttyAdapter
    public let resolver: FocusResolver
    public let store: ContextStore

    private let validator: PathValidating
    private var hostVersion: String?
    private var background: [BackgroundPaneInfo] = []
    private var lastTargetPaneID: String?
    private var hasObserved = false

    public init(adapter: GhosttyAdapter, validator: PathValidating = FileSystemPathValidator()) {
        self.adapter = adapter
        self.validator = validator
        self.resolver = FocusResolver()
        self.store = ContextStore(
            factory: adapter.factory,
            resolver: resolver,
            validator: validator,
            initialConnection: .unavailable
        )
    }

    /// 한 번 조회해 반영한다.
    @discardableResult
    public func refresh() -> Outcome {
        do {
            let snapshot = try adapter.snapshot()
            hostVersion = snapshot.version

            guard adapter.isVersionSupported(snapshot.version) else {
                store.markConnectionLost(
                    .incompatible,
                    reason: "Ghostty AppleScript requires \(GhosttyAdapter.minimumVersion)+ (found \(snapshot.version ?? "-"))"
                )
                return .unchanged
            }
            store.noteConnection(.connected)

            let result = GhosttySnapshotApplier.apply(
                snapshot,
                adapter: adapter,
                store: store,
                resolver: resolver,
                validator: validator
            )
            background = result.background
            let outcome: Outcome = hasObserved
                ? (lastTargetPaneID == result.target?.terminalID ? .unchanged : .changed)
                : .startup
            hasObserved = true
            lastTargetPaneID = result.target?.terminalID
            return outcome
        } catch let failure as GhosttyQueryError {
            if failure.connectionStatus == .connected {
                // 창이 없는 경우. 연결은 정상이고 대상만 없다.
                store.noteConnection(.connected)
                store.noteFailure(failure.diagnosticText)
            } else {
                store.markConnectionLost(failure.connectionStatus, reason: failure.diagnosticText)
            }
            return .unchanged
        } catch {
            store.markConnectionLost(.unavailable, reason: "\(error)")
            return .unchanged
        }
    }

    public func diagnostic() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            current: store.current ?? adapter.factory.unresolvedWorkInfo(
                generation: resolver.generation,
                connection: store.connection
            ),
            previous: store.previous,
            cachedPaneCount: store.cachedPaneCount,
            serverVersion: nil,
            protocolVersion: nil,
            expectedProtocolVersion: 0,
            socketPath: "-",
            callerPaneID: nil,
            hostVersion: hostVersion,
            backgroundPanes: background
        )
    }
}
