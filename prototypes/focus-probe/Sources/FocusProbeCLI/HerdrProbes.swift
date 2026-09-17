import FocusProbeCore
import Foundation

// ⚠️ 실험 코드 — 새 정상 실행 경로에서 쓰지 않는다.
//
// Herdr 내부 pane 자동 추적은 지원 범위에서 제외되었다(2026-09-16 범위 결정, docs/scope-decisions.md).
// 이유: 원격 SSH 클라이언트가 붙으면 서버 전역 focused_pane_id가 그쪽을 따라가고,
// 클라이언트별 포커스를 읽는 공식 API가 없다. Herdr 자체 수정 없이는 로컬 귀속을 확정할 수 없다.
//
// 이 코드는 조사·재현을 위해 보존한다. `--adapter herdr`로만 도달한다.

enum HerdrExperimental {
    static let note = "herdr adapter (experimental, out of supported scope)"
}

/// 이벤트 이름은 구독 요청(점 표기)과 실제 발행(밑줄 표기)이 다르다.
/// `HerdrEvent.normalizedName`이 둘을 흡수한다.
enum FocusEvents {
    static let types = ["pane.focused", "pane.updated", "pane.closed", "tab.focused", "workspace.focused"]
    /// 포커스가 바뀔 수 있는 이벤트. 이때만 대상 pane을 다시 고른다.
    static let changing: Set<String> = ["pane.focused", "pane.closed", "tab.focused", "workspace.focused"]
}

final class HerdrOnceProbe {
    let adapter: HerdrAdapter
    let resolver: FocusResolver
    let store: ContextStore
    let socketPath: String
    let showCaller: Bool

    private var capturedServerVersion: String?
    private var capturedProtocolVersion: Int?

    init(socketPath: String, showCaller: Bool, timeout: TimeInterval) {
        self.socketPath = socketPath
        self.showCaller = showCaller
        self.resolver = FocusResolver()
        self.adapter = HerdrAdapter(client: HerdrSocketClient(socketPath: socketPath, timeout: timeout))
        self.store = ContextStore(
            factory: adapter.factory,
            resolver: resolver,
            validator: FileSystemPathValidator(),
            initialConnection: .unavailable
        )
    }

    func run() -> DiagnosticSnapshot {
        do {
            let bootstrap = try adapter.bootstrap()
            capturedServerVersion = bootstrap.serverVersion
            capturedProtocolVersion = bootstrap.protocolVersion

            guard adapter.isProtocolCompatible(bootstrap.protocolVersion) else {
                // protocol이 다르면 pane 데이터를 해석하지 않는다. 값을 추측하지 않는다.
                store.markConnectionLost(
                    .incompatible,
                    reason: "protocol \(bootstrap.protocolVersion.map(String.init) ?? "-") != \(HerdrAdapter.expectedProtocolVersion)"
                )
                return snapshot()
            }
            store.noteConnection(.connected)

            guard let focused = bootstrap.focusedPane else {
                store.noteFailure("focused pane not reported by herdr")
                return snapshot()
            }

            store.alignTarget(to: focused)
            let record = try adapter.pane(id: focused.paneID)
            _ = store.apply(PaneObservation(generation: resolver.generation, record: record))
            return snapshot()
        } catch let failure as HerdrConnectionFailure {
            store.markConnectionLost(failure.connectionStatus, reason: failure.diagnosticText)
            return snapshot()
        } catch let failure as HerdrProtocolFailure {
            store.markConnectionLost(.unavailable, reason: failure.diagnosticText)
            return snapshot()
        } catch {
            store.markConnectionLost(.unavailable, reason: "\(error)")
            return snapshot()
        }
    }

    func snapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            current: store.current ?? unknownInfo(factory: adapter.factory, generation: resolver.generation, connection: store.connection),
            previous: store.previous,
            cachedPaneCount: store.cachedPaneCount,
            serverVersion: capturedServerVersion,
            protocolVersion: capturedProtocolVersion,
            expectedProtocolVersion: HerdrAdapter.expectedProtocolVersion,
            socketPath: socketPath,
            callerPaneID: callerPaneID(show: showCaller)
        )
    }
}

final class HerdrWatchProbe {
    let adapter: HerdrAdapter
    let resolver: FocusResolver
    let store: ContextStore
    let socketPath: String
    let showCaller: Bool

    private let renderer: ChangeRenderer
    private var subscription: HerdrSubscription?
    private var serverVersion: String?
    private var protocolVersion: Int?

    init(socketPath: String, intervalMilliseconds: Int, json: Bool, showCaller: Bool) {
        self.socketPath = socketPath
        self.showCaller = showCaller
        self.renderer = ChangeRenderer(json: json)
        self.resolver = FocusResolver()
        // 안전 재확인 주기와 소켓 타임아웃을 같은 값으로 맞춘다.
        let timeout = TimeInterval(intervalMilliseconds) / 1000.0
        self.adapter = HerdrAdapter(client: HerdrSocketClient(socketPath: socketPath, timeout: timeout))
        self.store = ContextStore(
            factory: adapter.factory,
            resolver: resolver,
            validator: FileSystemPathValidator(),
            initialConnection: .unavailable
        )
    }

    func run() {
        while true {
            if subscription == nil && !openSubscription() {
                store.markConnectionLost(.unavailable, reason: "cannot open herdr socket \(socketPath)")
                render(reason: "connect-failed")
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            refreshFocus(reason: "focus-check")
            guard let subscription else { continue }
            do {
                while true {
                    if let event = try subscription.nextEvent() {
                        handle(event)
                    } else {
                        // 이벤트를 놓쳤을 때를 대비한 안전 재확인.
                        refreshFocus(reason: "safety-poll")
                    }
                }
            } catch {
                subscription.close()
                self.subscription = nil
                store.markConnectionLost(.unavailable, reason: "\(error)")
                render(reason: "disconnected")
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func openSubscription() -> Bool {
        do {
            subscription = try adapter.subscribe(types: FocusEvents.types)
            store.markReconnected()
            serverVersion = nil
            protocolVersion = nil
            return true
        } catch {
            return false
        }
    }

    private func handle(_ event: HerdrEvent) {
        let name = event.normalizedName
        if FocusEvents.changing.contains(name) {
            refreshFocus(reason: "event:\(event.name)")
        } else if name == "pane.updated", event.paneID == resolver.targetPaneID {
            refreshFocus(reason: "event:\(event.name)")
        }
    }

    /// 실제 포커스를 다시 고르고 대상 pane의 경로를 새로 읽는다.
    private func refreshFocus(reason: String) {
        do {
            let bootstrap = try adapter.bootstrap()
            serverVersion = bootstrap.serverVersion
            protocolVersion = bootstrap.protocolVersion

            guard adapter.isProtocolCompatible(bootstrap.protocolVersion) else {
                store.markConnectionLost(
                    .incompatible,
                    reason: "protocol \(bootstrap.protocolVersion.map(String.init) ?? "-") != \(HerdrAdapter.expectedProtocolVersion)"
                )
                render(reason: reason)
                return
            }
            store.noteConnection(.connected)

            guard let focused = bootstrap.focusedPane else {
                store.noteFailure("focused pane not reported by herdr")
                render(reason: reason)
                return
            }

            let changed = resolver.targetPaneID != focused.paneID
            store.alignTarget(to: focused)
            let record = try adapter.pane(id: focused.paneID)
            _ = store.apply(PaneObservation(generation: resolver.generation, record: record))
            render(reason: changed ? "\(reason) → focus changed" : reason)
        } catch let failure as HerdrConnectionFailure {
            store.markConnectionLost(failure.connectionStatus, reason: failure.diagnosticText)
            render(reason: reason)
        } catch let failure as HerdrProtocolFailure {
            store.markConnectionLost(.unavailable, reason: failure.diagnosticText)
            render(reason: reason)
        } catch {
            store.markConnectionLost(.unavailable, reason: "\(error)")
            render(reason: reason)
        }
    }

    private func snapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            current: store.current ?? unknownInfo(factory: adapter.factory, generation: resolver.generation, connection: store.connection),
            previous: store.previous,
            cachedPaneCount: store.cachedPaneCount,
            serverVersion: serverVersion,
            protocolVersion: protocolVersion,
            expectedProtocolVersion: HerdrAdapter.expectedProtocolVersion,
            socketPath: socketPath,
            callerPaneID: callerPaneID(show: showCaller)
        )
    }

    private func render(reason: String) {
        renderer.render(snapshot(), reason: reason)
    }
}
