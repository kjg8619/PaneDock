import Foundation

public struct CheckResult: Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }

    public var line: String {
        "\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
    }
}

/// herdr 없이 돌아가는 결정적 검사.
///
/// 사용자 조작으로 안정적으로 재현할 수 없는 규칙(늦은 응답, 비활성 pane 갱신,
/// 새 pane 경로 미확인, 연결 단절)을 여기서 재현한다.
/// XCTest는 Command Line Tools 환경에서 사용할 수 없어(모듈 없음) CLI 모드로 둔다.
public enum SelfTest {
    public static func run() -> [CheckResult] {
        var results: [CheckResult] = []
        results.append(contentsOf: orderingChecks())
        results.append(contentsOf: targetSwitchChecks())
        results.append(contentsOf: backgroundPaneChecks())
        results.append(contentsOf: reconnectChecks())
        results.append(contentsOf: pathValidityChecks())
        results.append(contentsOf: connectionFailureChecks())
        results.append(contentsOf: normalizerChecks())
        results.append(contentsOf: eventDecodeChecks())
        results.append(contentsOf: ghosttyChecks())
        return results
    }

    // MARK: - 고정 장치

    private struct StubValidator: PathValidating {
        var directories: Set<String>
        func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    }

    private static let now = Date(timeIntervalSince1970: 1_789_540_000)

    private static func makeStore(
        directories: Set<String>
    ) -> (ContextStore, FocusResolver) {
        let factory = WorkInfoFactory(
            adapterID: HerdrAdapter.adapterID,
            hostAppID: "test-host",
            machineID: "local",
            defaultCWDSource: .paneCWD
        )
        let resolver = FocusResolver()
        let store = ContextStore(
            factory: factory,
            resolver: resolver,
            validator: StubValidator(directories: directories),
            initialConnection: .connected,
            clock: { now }
        )
        return (store, resolver)
    }

    private static func record(
        pane: String,
        workspace: String = "w1",
        tab: String = "w1:t1",
        cwd: String?,
        foreground: String? = nil,
        focused: Bool = true
    ) -> PaneRecord {
        PaneRecord(
            paneID: pane,
            workspaceID: workspace,
            tabID: tab,
            terminalID: "term-\(pane)",
            cwd: cwd,
            foregroundCWD: foreground ?? cwd,
            focused: focused,
            revision: 1,
            title: "pane \(pane)"
        )
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") -> CheckResult {
        CheckResult(name: name, passed: passed, detail: detail)
    }

    // MARK: - 검사

    /// D: 이전 pane의 늦은 응답이 현재 표시를 덮어쓰지 않는다.
    private static func orderingChecks() -> [CheckResult] {
        let (store, resolver) = makeStore(directories: ["/work/a", "/work/b"])
        store.alignTarget(to: record(pane: "w1:p1", cwd: "/work/a"))
        let firstGeneration = resolver.generation
        _ = store.apply(PaneObservation(generation: firstGeneration, record: record(pane: "w1:p1", cwd: "/work/a")))

        // 포커스가 B로 이동한 뒤, A에 대한 이전 세대 응답이 도착한다.
        store.alignTarget(to: record(pane: "w1:p2", cwd: "/work/b"))
        let lateOutcome = store.apply(
            PaneObservation(generation: firstGeneration, record: record(pane: "w1:p1", cwd: "/work/a"))
        )
        let stillB = store.current?.identity.paneID == "w1:p2"
        let notOverwritten = store.current?.reportedCWD == nil && store.current?.pathStatus == .pending

        return [
            check(
                "D: 이전 세대 응답 폐기",
                lateOutcome == .discardedStale && stillB && notOverwritten,
                "outcome=\(lateOutcome) pane=\(store.current?.identity.paneID ?? "-") path=\(store.current?.reportedCWD ?? "nil")"
            )
        ]
    }

    /// E: 새 pane의 경로가 확인되지 않으면 이전 경로를 새 경로처럼 표시하지 않는다.
    private static func targetSwitchChecks() -> [CheckResult] {
        let (store, _) = makeStore(directories: ["/work/a", "/work/b"])
        store.alignTarget(to: record(pane: "w1:p1", cwd: "/work/a"))
        // 이 검사는 **전환·경로 승격 규칙**을 본다. 포커스 판정은 명시적으로 준다
        // (판정 불가(nil)의 의미는 별도 검사가 담당한다).
        _ = store.apply(
            PaneObservation(generation: 1, record: record(pane: "w1:p1", cwd: "/work/a"), hostFrontmost: true)
        )
        let trackedBefore = store.current?.focusStatus == .tracked

        store.alignTarget(to: record(pane: "w1:p2", cwd: "/work/b"))
        let currentPending = store.current?.pathStatus == .pending && store.current?.focusStatus == .pending
        let currentHasNoPath = store.current?.reportedCWD == nil
        let previousKeptSeparate = store.previous?.reportedCWD == "/work/a" && store.previous?.identity.paneID == "w1:p1"
        let pendingDetail = "current.path=\(store.current?.reportedCWD ?? "nil") previous.path=\(store.previous?.reportedCWD ?? "nil")"

        _ = store.apply(
            PaneObservation(generation: store.focusGeneration, record: record(pane: "w1:p2", cwd: "/work/b"), hostFrontmost: true)
        )
        let pathUpdated = store.current?.reportedCWD == "/work/b"
            && store.current?.pathStatus == .valid
            && store.current?.focusStatus == .tracked
            && store.current?.identity.paneID == "w1:p2"
        let updatedDetail = "path=\(store.current?.reportedCWD ?? "nil") focus=\(store.current?.focusStatus.rawValue ?? "-")"

        return [
            check(
                "E: 전환 직후 pending, 이전 경로 미승격",
                trackedBefore && currentPending && currentHasNoPath && previousKeptSeparate,
                pendingDetail
            ),
            check("B: 같은 pane 경로 갱신", pathUpdated, updatedDetail)
        ]
    }

    /// C: 비활성 pane의 갱신은 현재 표시를 바꾸지 않는다.
    private static func backgroundPaneChecks() -> [CheckResult] {
        let (store, resolver) = makeStore(directories: ["/work/a", "/work/c"])
        store.alignTarget(to: record(pane: "w1:p1", cwd: "/work/a"))
        _ = store.apply(PaneObservation(generation: resolver.generation, record: record(pane: "w1:p1", cwd: "/work/a")))

        let outcome = store.apply(
            PaneObservation(generation: resolver.generation, record: record(pane: "w1:p9", cwd: "/work/c", focused: false))
        )
        let displayedUnchanged = store.current?.identity.paneID == "w1:p1" && store.current?.reportedCWD == "/work/a"
        let cached = store.cached("w1:p9")?.reportedCWD == "/work/c"

        return [
            check(
                "C: 비활성 pane은 캐시만 갱신",
                outcome == .cachedBackground && displayedUnchanged && cached,
                "outcome=\(outcome) displayed=\(store.current?.reportedCWD ?? "nil") cached=\(store.cached("w1:p9")?.reportedCWD ?? "nil")"
            )
        ]
    }

    /// F: 재연결 후 이전 연결의 응답을 새 상태로 오인하지 않는다.
    private static func reconnectChecks() -> [CheckResult] {
        let (store, resolver) = makeStore(directories: ["/work/b"])
        store.alignTarget(to: record(pane: "w1:p2", cwd: "/work/b"))
        let beforeReconnect = resolver.generation
        store.markReconnected()
        let afterReconnect = resolver.generation

        let oldOutcome = store.apply(
            PaneObservation(generation: beforeReconnect, record: record(pane: "w1:p2", cwd: "/work/b"))
        )
        let newOutcome = store.apply(
            PaneObservation(generation: afterReconnect, record: record(pane: "w1:p2", cwd: "/work/b"))
        )

        return [
            check(
                "F: 재연결 시 세대 증가 + 이전 연결 응답 폐기",
                afterReconnect > beforeReconnect && oldOutcome == .discardedStale && newOutcome == .applied,
                "gen \(beforeReconnect) -> \(afterReconnect), old=\(oldOutcome), new=\(newOutcome)"
            )
        ]
    }

    private static func pathValidityChecks() -> [CheckResult] {
        let (store, resolver) = makeStore(directories: ["/work/a"])
        store.alignTarget(to: record(pane: "w1:p1", cwd: "/work/a"))
        _ = store.apply(PaneObservation(generation: resolver.generation, record: record(pane: "w1:p1", cwd: "/work/a")))
        let valid = store.current?.pathStatus == .valid
        let sourceIsPaneCWD = store.current?.cwdSource == .paneCWD

        let (goneStore, goneResolver) = makeStore(directories: [])
        goneStore.alignTarget(to: record(pane: "w1:p1", cwd: "/deleted"))
        _ = goneStore.apply(PaneObservation(generation: goneResolver.generation, record: record(pane: "w1:p1", cwd: "/deleted")))
        let missing = goneStore.current?.pathStatus == .missing
        let missingNotTracked = goneStore.current?.focusStatus == .unknown

        let (noPathStore, noPathResolver) = makeStore(directories: [])
        noPathStore.alignTarget(to: record(pane: "w1:p1", cwd: nil))
        _ = noPathStore.apply(PaneObservation(generation: noPathResolver.generation, record: record(pane: "w1:p1", cwd: nil)))
        let unsupported = noPathStore.current?.pathStatus == .unsupported

        return [
            check(
                "경로 판정: 유효 / 사라짐 / 미제공 구분",
                valid && sourceIsPaneCWD && missing && missingNotTracked && unsupported,
                "valid=\(valid) source=\(store.current?.cwdSource?.rawValue ?? "-") missing=\(missing) unsupported=\(unsupported)"
            ),
            check(
                "R8: foreground_cwd를 별도 증거로 보존",
                store.current?.foregroundCWD == "/work/a" && store.current?.cwdSource == .paneCWD,
                "cwdSource=\(store.current?.cwdSource?.rawValue ?? "-") foreground=\(store.current?.foregroundCWD ?? "nil")"
            )
        ]
    }

    private static func connectionFailureChecks() -> [CheckResult] {
        let (store, resolver) = makeStore(directories: ["/work/a"])
        store.alignTarget(to: record(pane: "w1:p1", cwd: "/work/a"))
        _ = store.apply(PaneObservation(generation: resolver.generation, record: record(pane: "w1:p1", cwd: "/work/a")))

        store.markConnectionLost(.unavailable, reason: "socket not found")
        let statusSeparate = store.connection == .unavailable
        let notTracked = store.current?.focusStatus == .unknown
        let pathNotFabricated = store.current?.reportedCWD == "/work/a" && store.current?.connectionStatus == .unavailable

        let classification: [CheckResult] = [
            check("F: ENOENT → unavailable", HerdrSocketClient.classify(errno: ENOENT, path: "/x").connectionStatus == .unavailable),
            check("F: ECONNREFUSED → refused", HerdrSocketClient.classify(errno: ECONNREFUSED, path: "/x").connectionStatus == .refused),
            check("F: EACCES → denied", HerdrSocketClient.classify(errno: EACCES, path: "/x").connectionStatus == .denied)
        ]

        return [
            check(
                "F: 연결 오류와 추적 상태 분리",
                statusSeparate && notTracked && pathNotFabricated,
                "connection=\(store.connection.rawValue) focus=\(store.current?.focusStatus.rawValue ?? "-") path=\(store.current?.reportedCWD ?? "nil")"
            )
        ] + classification
    }

    private static func normalizerChecks() -> [CheckResult] {
        let cases: [(String, String, String)] = [
            ("/work/shop/../api", "/work/api", "상위 참조 정리"),
            ("/work//shop///api", "/work/shop/api", "중복 슬래시 정리"),
            ("/", "/", "루트 보존"),
            ("/work/shop/", "/work/shop", "끝 슬래시 제거"),
            ("relative/./path", "relative/path", "상대 경로 보존"),
        ]
        var results: [CheckResult] = []
        for (input, expected, label) in cases {
            let actual = PathNormalizer.normalize(input)
            results.append(check("정규화: \(label)", actual == expected, "\(input) -> \(actual)"))
        }
        return results
    }

    private static func eventDecodeChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        let direct = Data(#"{"event":"pane.focused","data":{"pane_id":"w1:p1"}}"#.utf8)
        let directEvent = try? HerdrSubscription.decode(line: direct)
        results.append(
            check(
                "이벤트 파싱: data.pane_id",
                directEvent?.name == "pane.focused" && directEvent?.paneID == "w1:p1",
                "\(directEvent.map { "\($0.name)/\($0.paneID ?? "-")" } ?? "nil")"
            )
        )

        let nested = Data(#"{"event":"pane.updated","data":{"pane":{"pane_id":"w2:p3"}}}"#.utf8)
        let nestedEvent = try? HerdrSubscription.decode(line: nested)
        results.append(
            check(
                "이벤트 파싱: data.pane.pane_id",
                nestedEvent?.paneID == "w2:p3",
                "\(nestedEvent?.paneID ?? "nil")"
            )
        )

        let notAnEvent = Data(#"{"id":"x","result":{"type":"pong"}}"#.utf8)
        let failed = (try? HerdrSubscription.decode(line: notAnEvent)) == nil
        results.append(check("이벤트 파싱: 비이벤트 프레임 거부", failed))

        // 설치본이 실제로 보낸 프레임은 밑줄 표기였다(pane_updated).
        // 구독 요청·SubscriptionEventKind는 점 표기를 쓰므로 둘 다 정규화되어야 한다.
        let observedFrame = Data(
            #"{"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"w3D:p6","cwd":"/work/a"}}}"#.utf8
        )
        let observedEvent = try? HerdrSubscription.decode(line: observedFrame)
        results.append(
            check(
                "이벤트 이름 정규화: 실제 발행 표기(pane_updated)",
                observedEvent?.normalizedName == "pane.updated" && observedEvent?.paneID == "w3D:p6",
                "\(observedEvent?.name ?? "nil") -> \(observedEvent?.normalizedName ?? "-") / \(observedEvent?.paneID ?? "-")"
            )
        )
        results.append(
            check(
                "이벤트 이름 정규화: 점 표기(pane.focused)",
                HerdrEvent(name: "pane.focused", paneID: nil).normalizedName == "pane.focused"
            )
        )
        results.append(
            check(
                "이벤트 이름 정규화: 밑줄 표기(pane_focused)",
                HerdrEvent(name: "pane_focused", paneID: nil).normalizedName == "pane.focused"
            )
        )

        return results
    }

    // MARK: - Ghostty (정상 실행 경로)

    private final class StubAppleScript: AppleScriptRunning, @unchecked Sendable {
        private var outputs: [String]

        init(outputs: [String]) {
            self.outputs = outputs
        }

        func run(_ source: String) throws -> String {
            guard !outputs.isEmpty else { throw TerminalHostQueryError.other("stub exhausted") }
            return outputs.removeFirst()
        }
    }

    /// AppleScript 스크립트가 실제로 내는 것과 같은 형식의 출력을 만든다.
    ///
    /// Ghostty와 cmux가 **같은 형식**을 쓴다. `focused`가 nil이면 `focusedTerminal`/`focusedWD` 줄이
    /// 없고, `focusedPanelIsTerminal`이 주어지면 그 줄이 추가된다(터미널이 아닌 패널을 뜻한다).
    private static func hostOutput(
        version: String = "1.3.1",
        frontmost: Bool = true,
        frontWindow: String = "win-1",
        selectedTab: String = "tab-1",
        focused: String? = "term-A",
        focusedPanelIsTerminal: Bool? = nil,
        terminals: [(window: String, tab: String, id: String, wd: String?, name: String?)]
    ) -> String {
        var lines: [String] = [
            "version=\(version)",
            "frontmost=\(frontmost)",
            "frontWindow=\(frontWindow)",
            "selectedTab=\(selectedTab)",
        ]
        if let focused {
            lines.append("focusedTerminal=\(focused)")
            lines.append("focusedWD=\(terminals.first { $0.id == focused }?.wd ?? "")")
        }
        if let focusedPanelIsTerminal {
            lines.append("focusedPanelIsTerminal=\(focusedPanelIsTerminal)")
        }
        for terminal in terminals {
            lines.append("term=\(terminal.window)\t\(terminal.tab)\t\(terminal.id)\t\(terminal.wd ?? "")\t\(terminal.name ?? "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Adapter 종류와 무관하게 같은 조회·반영 경로를 세운다. 두 Adapter의 차이는 Adapter뿐이다.
    private static func makeHostStore<A: TerminalHostAdapter>(
        _ adapter: A,
        directories: Set<String>
    ) -> (adapter: A, store: ContextStore, resolver: FocusResolver, validator: StubValidator) {
        let resolver = FocusResolver()
        let validator = StubValidator(directories: directories)
        let store = ContextStore(
            factory: adapter.factory,
            resolver: resolver,
            validator: validator,
            initialConnection: .unavailable,
            clock: { now }
        )
        return (adapter, store, resolver, validator)
    }

    private static func makeGhosttyStore(
        directories: Set<String>,
        outputs: [String]
    ) -> (adapter: GhosttyAdapter, store: ContextStore, resolver: FocusResolver, validator: StubValidator) {
        makeHostStore(GhosttyAdapter(runner: StubAppleScript(outputs: outputs)), directories: directories)
    }

    private static func makeCmuxStore(
        directories: Set<String>,
        identifies: [CmuxIdentify],
        sidebars: [CmuxSidebarState],
        frontmost: StubFrontmostApp = StubFrontmostApp(CmuxAdapter.bundleIdentifier)
    ) -> (adapter: CmuxAdapter, store: ContextStore, resolver: FocusResolver, validator: StubValidator) {
        makeHostStore(
            CmuxAdapter(client: StubCmuxQueries(identifies: identifies, sidebars: sidebars), frontmost: frontmost),
            directories: directories
        )
    }

    private static func ghosttyChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        let twoPanes = [
            (window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?),
            (window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/b", name: "b" as String?),
        ]

        // A: 다른 terminal로 전환하면 새 pane과 새 경로가 나오고, 이전 경로는 previous로만 남는다.
        do {
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a", "/work/b"],
                outputs: [
                    hostOutput(focused: "term-A", terminals: twoPanes),
                    hostOutput(focused: "term-B", terminals: twoPanes),
                ]
            )
            let first = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let firstPane = store.current?.identity.paneID
            let firstPath = store.current?.reportedCWD

            let second = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let secondPane = store.current?.identity.paneID
            let secondPath = store.current?.reportedCWD
            let previousPath = store.previous?.reportedCWD

            results.append(
                check(
                    "A: pane 전환 시 새 식별자와 새 경로",
                    firstPane == "term-A" && firstPath == "/work/a"
                        && secondPane == "term-B" && secondPath == "/work/b"
                        && previousPath == "/work/a"
                        && store.current?.focusStatus == .tracked,
                    "\(firstPane ?? "-")/\(firstPath ?? "-") → \(secondPane ?? "-")/\(secondPath ?? "-") previous=\(previousPath ?? "-")"
                )
            )
        } catch {
            results.append(check("A: pane 전환 시 새 식별자와 새 경로", false, "\(error)"))
        }

        // B: 같은 terminal에서 경로만 바뀌면 pane ID는 유지된다.
        do {
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a", "/work/c"],
                outputs: [
                    hostOutput(focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?)]),
                    hostOutput(focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/c", name: "a" as String?)]),
                ]
            )
            let first = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let generationBefore = store.focusGeneration
            let second = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)

            results.append(
                check(
                    "B: 같은 pane에서 경로만 갱신",
                    store.current?.identity.paneID == "term-A"
                        && store.current?.reportedCWD == "/work/c"
                        && store.focusGeneration == generationBefore,
                    "pane=\(store.current?.identity.paneID ?? "-") path=\(store.current?.reportedCWD ?? "-") gen=\(store.focusGeneration)"
                )
            )
        } catch {
            results.append(check("B: 같은 pane에서 경로만 갱신", false, "\(error)"))
        }

        // C: 비활성 terminal의 경로가 바뀌어도 대상은 그대로다.
        do {
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a", "/work/b", "/work/c"],
                outputs: [
                    hostOutput(focused: "term-A", terminals: twoPanes),
                    hostOutput(
                        focused: "term-A",
                        terminals: [
                            (window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?),
                            (window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/c", name: "b" as String?),
                        ]
                    ),
                ]
            )
            let first = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let second = try adapter.snapshot()
            let result = TerminalHostSnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)

            let backgroundMoved = result.background.first { $0.paneID == "term-B" }?.reportedCWD
            results.append(
                check(
                    "C: 비활성 pane 갱신은 대상을 바꾸지 않는다",
                    store.current?.identity.paneID == "term-A"
                        && store.current?.reportedCWD == "/work/a"
                        && backgroundMoved == "/work/c",
                    "target=\(store.current?.identity.paneID ?? "-") path=\(store.current?.reportedCWD ?? "-") background-B=\(backgroundMoved ?? "-")"
                )
            )
        } catch {
            results.append(check("C: 비활성 pane 갱신은 대상을 바꾸지 않는다", false, "\(error)"))
        }

        // D: 이전 세대 응답은 Ghostty 레코드에서도 폐기된다.
        do {
            let (_, store, _, _) = makeGhosttyStore(directories: ["/work/a", "/work/b"], outputs: [])
            let recordA = PaneRecord(paneID: "term-A", workspaceID: "win-1", tabID: "tab-1", terminalID: "term-A", cwd: "/work/a", foregroundCWD: nil, focused: true, revision: nil, title: nil)
            let recordB = PaneRecord(paneID: "term-B", workspaceID: "win-1", tabID: "tab-1", terminalID: "term-B", cwd: "/work/b", foregroundCWD: nil, focused: true, revision: nil, title: nil)

            store.alignTarget(to: recordA)
            let staleGeneration = store.focusGeneration
            _ = store.apply(PaneObservation(generation: staleGeneration, record: recordA))
            store.alignTarget(to: recordB)
            let lateOutcome = store.apply(PaneObservation(generation: staleGeneration, record: recordA))

            results.append(
                check(
                    "D: Ghostty 레코드의 늦은 응답 폐기",
                    lateOutcome == .discardedStale && store.current?.identity.paneID == "term-B",
                    "outcome=\(lateOutcome) pane=\(store.current?.identity.paneID ?? "-")"
                )
            )
        }

        // E: 경로가 없거나 디렉터리가 아니면 정상 추적과 구분한다.
        do {
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a"],
                outputs: [
                    hostOutput(
                        focused: "term-A",
                        terminals: [
                            (window: "win-1", tab: "tab-1", id: "term-A", wd: nil, name: "no-path" as String?),
                            (window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/gone", name: "gone" as String?),
                        ]
                    )
                ]
            )
            let snapshot = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(snapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let noPath = store.current?.pathStatus == .unsupported && store.current?.focusStatus == .unknown

            let (adapter2, store2, resolver2, validator2) = makeGhosttyStore(
                directories: [],
                outputs: [hostOutput(focused: "term-B", terminals: [(window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/gone", name: "gone" as String?)])]
            )
            let snapshot2 = try adapter2.snapshot()
            TerminalHostSnapshotApplier.apply(snapshot2, adapter: adapter2, store: store2, resolver: resolver2, validator: validator2)
            let missing = store2.current?.pathStatus == .missing && store2.current?.focusStatus == .unknown

            results.append(
                check(
                    "E: 경로 미제공/사라짐을 정상 추적과 구분",
                    noPath && missing,
                    "unsupported=\(noPath) missing=\(missing)"
                )
            )
        } catch {
            results.append(check("E: 경로 미제공/사라짐을 정상 추적과 구분", false, "\(error)"))
        }

        // 바깥 앱이 최전면이 아니면 경로가 유효해도 "유지 중"으로 표시한다.
        do {
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a"],
                outputs: [hostOutput(frontmost: false, focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?)])]
            )
            let snapshot = try adapter.snapshot()
            TerminalHostSnapshotApplier.apply(snapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "최전면 아님 + 유효 경로 → held",
                    store.current?.focusStatus == .held && store.current?.reportedCWD == "/work/a",
                    "focus=\(store.current?.focusStatus.rawValue ?? "-") hostFrontmost=\(store.current?.hostFrontmost.map(String.init) ?? "-")"
                )
            )
        } catch {
            results.append(check("최전면 아님 + 유효 경로 → held", false, "\(error)"))
        }

        results.append(contentsOf: ghosttyErrorChecks())
        results.append(contentsOf: ghosttyParseChecks())
        results.append(contentsOf: dockChecks())
        results.append(contentsOf: settingsChecks())
        results.append(contentsOf: projectChecks())
        results.append(contentsOf: cmuxChecks())
        results.append(contentsOf: hostRouterChecks())
        results.append(contentsOf: hostBoundaryChecks())
        return results
    }

    // MARK: - 프로젝트 매칭·링크 (0.1c)

    private static func projectChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        let shop = Project(
            id: "shop",
            name: "Shop",
            root: "/work/shop",
            links: [
                ProjectLink(id: "repo", name: "저장소", url: "https://example.com/shop/repo"),
                ProjectLink(id: "docs", name: "문서", url: "https://example.com/shop/docs"),
            ]
        )
        let admin = Project(
            id: "admin",
            name: "Shop Admin",
            root: "/work/shop/admin",
            links: [ProjectLink(id: "repo", name: "저장소", url: "https://example.com/admin")]
        )
        let catalog = ProjectCatalog(projects: [shop, admin])

        // A/B 경로에 맞는 이름과 링크
        let shopResolution = ProjectResolver.resolve(cwd: "/work/shop/api", catalog: catalog)
        let adminResolution = ProjectResolver.resolve(cwd: "/work/shop/admin/src", catalog: catalog)
        results.append(
            check(
                "프로젝트: 경로에 맞는 이름과 링크 구성",
                shopResolution?.projectName == "Shop"
                    && shopResolution?.links.map(\.linkID) == ["repo", "docs"]
                    && adminResolution?.projectName == "Shop Admin"
                    && adminResolution?.links.map(\.linkID) == ["repo"],
                "shop=\(shopResolution?.projectName ?? "-")/\(shopResolution?.links.count ?? -1) links admin=\(adminResolution?.projectName ?? "-")/\(adminResolution?.links.count ?? -1)"
            )
        )

        // 중첩 기준 폴더: 더 구체적인 것이 이긴다
        results.append(
            check(
                "프로젝트: 여러 기준 폴더가 맞으면 가장 구체적인 것",
                adminResolution?.projectRoot == "/work/shop/admin",
                "root=\(adminResolution?.projectRoot ?? "-")"
            )
        )

        // 기준 폴더 자체도 매칭된다
        results.append(
            check(
                "프로젝트: 기준 폴더 자신도 매칭",
                ProjectResolver.resolve(cwd: "/work/shop", catalog: catalog)?.projectID == "shop"
            )
        )

        // 비슷한 이름의 다른 폴더 오매칭 방지
        let shopOld = ProjectResolver.resolve(cwd: "/work/shop-old/api", catalog: catalog)
        let shopOldish = ProjectResolver.resolve(cwd: "/work/shopping", catalog: catalog)
        results.append(
            check(
                "프로젝트: 폴더 경계 — shop-old/shopping은 shop이 아니다",
                shopOld == nil && shopOldish == nil,
                "shop-old=\(shopOld?.projectID ?? "nil") shopping=\(shopOldish?.projectID ?? "nil")"
            )
        )

        // 미등록 경로 → 기본 Dock
        results.append(
            check(
                "프로젝트: 미등록 경로는 기본 Dock(판정 없음)",
                ProjectResolver.resolve(cwd: "/other/place", catalog: catalog) == nil
                    && ProjectResolver.resolve(cwd: "/other", catalog: ProjectCatalog()) == nil
            )
        )

        // 중복 기준 폴더 → 모호, 선택하지 않음
        let duplicateA = Project(id: "a", name: "A", root: "/dup/root", links: [])
        let duplicateB = Project(id: "b", name: "B", root: "/dup/root", links: [])
        let duplicateMatch = ProjectMatcher.match(cwd: "/dup/root/x", in: ProjectCatalog(projects: [duplicateA, duplicateB]))
        let duplicateResolution = ProjectResolver.resolve(cwd: "/dup/root/x", catalog: ProjectCatalog(projects: [duplicateA, duplicateB]))
        var ambiguousIDs: [String] = []
        if case .ambiguous(_, let ids) = duplicateMatch { ambiguousIDs = ids }
        results.append(
            check(
                "프로젝트: 중복 기준 폴더는 모호로 안내하고 고르지 않음",
                ambiguousIDs == ["a", "b"] && duplicateResolution == nil,
                "ids=\(ambiguousIDs) resolution=\(duplicateResolution == nil ? "nil" : "있음")"
            )
        )

        // 잘못된 URL → 목록에서 제외 + 진단
        let mixed = Project(
            id: "mixed",
            name: "Mixed",
            root: "/work/mixed",
            links: [
                ProjectLink(id: "ok", name: "정상", url: "https://example.com/ok"),
                ProjectLink(id: "ftp", name: "FTP", url: "ftp://example.com/nope"),
                ProjectLink(id: "js", name: "스크립트", url: "javascript:alert(1)"),
            ]
        )
        let mixedCatalog = ProjectCatalog(projects: [mixed])
        let mixedDiagnostics = ProjectCatalogValidator.diagnostics(for: mixedCatalog)
        let mixedResolution = ProjectResolver.resolve(cwd: "/work/mixed", catalog: mixedCatalog, catalogDiagnostics: mixedDiagnostics)
        results.append(
            check(
                "프로젝트: http/https 외 링크는 제외하고 진단에 남김",
                mixedResolution?.links.map(\.linkID) == ["ok"]
                    && mixedDiagnostics.contains { $0.contains("ftp://") }
                    && mixedDiagnostics.contains { $0.contains("javascript:") },
                "links=\(mixedResolution?.links.map(\.linkID) ?? []) 진단=\(mixedDiagnostics.count)건"
            )
        )

        // 중복 id 진단
        let duplicateLinks = Project(
            id: "duplink",
            name: "Dup",
            root: "/work/dup",
            links: [
                ProjectLink(id: "same", name: "1", url: "https://example.com/1"),
                ProjectLink(id: "same", name: "2", url: "https://example.com/2"),
            ]
        )
        let duplicateProjectIDs = ProjectCatalog(projects: [shop, Project(id: "shop", name: "다른 Shop", root: "/work/other", links: [])])
        let dupLinkDiagnostics = ProjectCatalogValidator.diagnostics(for: ProjectCatalog(projects: [duplicateLinks]))
        let dupProjectDiagnostics = ProjectCatalogValidator.diagnostics(for: duplicateProjectIDs)
        results.append(
            check(
                "프로젝트: 중복 id(프로젝트·링크)를 진단",
                dupLinkDiagnostics.contains { $0.contains("링크 id가 중복") }
                    && dupProjectDiagnostics.contains { $0.contains("프로젝트 id가 중복") },
                "링크=\(dupLinkDiagnostics.count)건 프로젝트=\(dupProjectDiagnostics.count)건"
            )
        )

        // 대소문자는 그대로 비교한다
        let caseCatalog = ProjectCatalog(projects: [Project(id: "case", name: "Case", root: "/Work/Shop", links: [])])
        results.append(
            check(
                "프로젝트: 대소문자를 임의로 소문자화하지 않는다",
                ProjectMatcher.match(cwd: "/work/shop/api", in: caseCatalog) == .none
                    && ProjectMatcher.match(cwd: "/Work/Shop/api", in: caseCatalog) != .none,
                "소문자경로=\(ProjectMatcher.match(cwd: "/work/shop/api", in: caseCatalog))"
            )
        )

        // 심볼릭 링크: 링크를 해석해 같은 폴더로 본다
        do {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pane-dock-proj-\(UUID().uuidString)")
            let real = base.appendingPathComponent("real")
            try? FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let alias = base.appendingPathComponent("alias")
            try? FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: real.path)
            let linkCatalog = ProjectCatalog(projects: [
                Project(id: "linked", name: "Linked", root: alias.path, links: [])
            ])
            let viaReal = ProjectMatcher.match(cwd: real.appendingPathComponent("sub").path, in: linkCatalog)
            let viaAlias = ProjectMatcher.match(cwd: alias.appendingPathComponent("sub").path, in: linkCatalog)
            results.append(
                check(
                    "프로젝트: 심볼릭 링크는 해석해 같은 폴더로 판정",
                    viaReal != .none && viaAlias != .none,
                    "real경유=\(viaReal != .none) alias경유=\(viaAlias != .none)"
                )
            )
            try? FileManager.default.removeItem(at: base)
        }

        // 카탈로그 로드: 없음 / 손상 / 미래 버전 — **원본 파일을 건드리지 않는다**
        do {
            let url = temporarySettingsURL().deletingLastPathComponent().appendingPathComponent("projects.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fresh = ProjectCatalogStore(url: url)
            let freshOK = fresh.outcome == .fresh

            let garbage = Data("{ broken ".utf8)
            try? garbage.write(to: url)
            let corrupt = ProjectCatalogStore(url: url)
            let corruptUntouched = (try? Data(contentsOf: url)) == garbage
            let noBackupLeft = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?.count == 1

            let future = Data(#"{"schemaVersion":9,"projects":[]}"#.utf8)
            try? future.write(to: url)
            let unsupported = ProjectCatalogStore(url: url)
            let futureUntouched = (try? Data(contentsOf: url)) == future

            results.append(
                check(
                    "프로젝트 카탈로그: 없음/손상/미래버전을 처리하고 원본을 고치지 않는다",
                    freshOK
                        && corrupt.outcome == .corrupt && corruptUntouched && noBackupLeft
                        && unsupported.outcome == .unsupportedVersion(found: 9) && futureUntouched,
                    "fresh=\(freshOK) 손상=\(corrupt.outcome.label)/원본보존=\(corruptUntouched)/백업안만듦=\(noBackupLeft) 미래=\(unsupported.outcome.label)/보존=\(futureUntouched)"
                )
            )
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        results.append(contentsOf: projectReloadChecks())
        results.append(contentsOf: projectCatalogApplyChecks(shop: shop))
        results.append(contentsOf: projectActionChecks(shop: shop, catalog: catalog))
        return results
    }

    /// 다시 읽기 결과를 "하나의 구성"으로 확정하는 판단 (앱이 그대로 쓴다).
    private static func projectCatalogApplyChecks(shop: Project) -> [CheckResult] {
        var results: [CheckResult] = []
        let previous = ProjectCatalog(projects: [shop])
        let previousDiagnostics = ["이전 경고"]

        // 정상 로딩 → 새 구성 적용
        let newCatalog = ProjectCatalog(projects: [shop, Project(id: "extra", name: "Extra", root: "/work/extra", links: [])])
        let applied = ProjectCatalogApplier.apply(
            load: .loaded, loadedCatalog: newCatalog, loadedDiagnostics: [],
            previousCatalog: previous, previousDiagnostics: previousDiagnostics, isReload: true
        )
        results.append(
            check(
                "다시 읽기: 정상 로딩은 새 구성을 적용하고 결과를 안내한다",
                applied.appliedNewConfiguration
                    && applied.catalog.projects.count == 2
                    && applied.note?.contains("프로젝트 2개") == true
                    && applied.diagnostics.isEmpty,
                "적용=\(applied.appliedNewConfiguration) 프로젝트=\(applied.catalog.projects.count) 안내=\(applied.note?.replacingOccurrences(of: "\n", with: " / ") ?? "-")"
            )
        )

        // 치명적 실패 → 이전 구성 유지 + 명확한 안내
        for (label, outcome) in [("손상", ProjectCatalogLoadOutcome.corrupt), ("미래버전", .unsupportedVersion(found: 9))] {
            let failed = ProjectCatalogApplier.apply(
                load: outcome, loadedCatalog: ProjectCatalog(), loadedDiagnostics: [],
                previousCatalog: previous, previousDiagnostics: previousDiagnostics, isReload: true
            )
            results.append(
                check(
                    "다시 읽기: \(label)이면 이전 구성을 유지하고 '이전 설정 사용 중'을 표시",
                    !failed.appliedNewConfiguration
                        && failed.catalog.projects.count == 1
                        && failed.catalog.projects.first?.id == shop.id
                        && failed.diagnostics == previousDiagnostics
                        && failed.note?.contains("설정 읽기 실패") == true
                        && failed.note?.contains("이전 설정 사용 중") == true,
                    "적용=\(failed.appliedNewConfiguration) 프로젝트=\(failed.catalog.projects.count) 안내=\(failed.note?.prefix(30) ?? "-")"
                )
            )
        }

        // 파일 없음(fresh) → 빈 카탈로그 적용 = 기본 Dock
        let cleared = ProjectCatalogApplier.apply(
            load: .fresh, loadedCatalog: ProjectCatalog(), loadedDiagnostics: [],
            previousCatalog: previous, previousDiagnostics: previousDiagnostics, isReload: true
        )
        results.append(
            check(
                "다시 읽기: 파일이 없으면 기본 Dock으로 돌아간다",
                cleared.appliedNewConfiguration
                    && cleared.catalog.projects.isEmpty
                    && cleared.diagnostics.isEmpty
                    && cleared.note?.contains("기본 Dock") == true,
                "적용=\(cleared.appliedNewConfiguration) 프로젝트=\(cleared.catalog.projects.count) 안내=\(cleared.note ?? "-")"
            )
        )

        // 경고는 유지되고 안내에 포함된다
        let warned = ProjectCatalogApplier.apply(
            load: .loaded, loadedCatalog: newCatalog, loadedDiagnostics: ["기준 폴더가 중복 등록되었습니다: /dup → a, b"],
            previousCatalog: previous, previousDiagnostics: [], isReload: true
        )
        results.append(
            check(
                "다시 읽기: 로더 경고를 조용히 무시하지 않고 안내에 포함",
                warned.diagnostics.count == 1 && warned.note?.contains("중복 등록") == true,
                "경고=\(warned.diagnostics.count) 안내=\(warned.note?.replacingOccurrences(of: "\n", with: " / ") ?? "-")"
            )
        )

        // 시작 시에는 성공 안내를 띄우지 않는다(잘못이 없으면 조용히)
        let startup = ProjectCatalogApplier.apply(
            load: .loaded, loadedCatalog: newCatalog, loadedDiagnostics: [],
            previousCatalog: ProjectCatalog(), previousDiagnostics: [], isReload: false
        )
        results.append(
            check(
                "다시 읽기: 시작 시 정상 로딩은 불필요한 안내를 띄우지 않는다",
                startup.note == nil && startup.appliedNewConfiguration,
                "안내=\(startup.note ?? "nil")"
            )
        )

        return results
    }

    // MARK: - 설정 다시 읽기 (0.1d)

    private static func projectReloadChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        func write(_ json: String, to url: URL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(json.utf8).write(to: url)
        }

        let shopJSON = #"{"schemaVersion":1,"projects":[{"id":"shop","name":"Shop","root":"/work/shop","links":[{"id":"repo","name":"저장소","url":"https://example.com/a"},{"id":"docs","name":"문서","url":"https://example.com/b"}]}]}"#

        // 1) 정상 변경 반영 + 사용자 파일 불변
        do {
            let url = temporarySettingsURL().deletingLastPathComponent().appendingPathComponent("projects.json")
            write(shopJSON, to: url)
            let store = ProjectCatalogStore(url: url)
            let first = ProjectResolver.resolve(cwd: "/work/shop/api", catalog: store.catalog)

            // 링크 URL·순서 변경
            let changedJSON = #"{"schemaVersion":1,"projects":[{"id":"shop","name":"Shop","root":"/work/shop","links":[{"id":"docs","name":"문서","url":"https://example.com/b2"},{"id":"repo","name":"저장소","url":"https://example.com/a"}]}]}"#
            write(changedJSON, to: url)
            // store가 건드리지 않았다면 reload 후에도 이 바이트 그대로여야 한다.
            let expectedAfterReload = try? Data(contentsOf: url)
            let outcome = store.reload()
            let after = try? Data(contentsOf: url)
            let second = ProjectResolver.resolve(cwd: "/work/shop/api", catalog: store.catalog)

            results.append(
                check(
                    "재로딩: 정상 변경을 반영하고 사용자 파일은 건드리지 않는다",
                    outcome == .loaded
                        && first?.links.map(\.linkID) == ["repo", "docs"]
                        && second?.links.map(\.linkID) == ["docs", "repo"]
                        && second?.links.first?.url == "https://example.com/b2"
                        && after == expectedAfterReload,
                    "1차=\(first?.links.map(\.linkID) ?? []) 2차=\(second?.links.map(\.linkID) ?? []) 파일불변=\(after == expectedAfterReload)"
                )
            )
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        // 2) 파일 없음 → 기본 Dock + 3) 손상/미래버전 → 적용 불가(이전 구성 유지 판단은 앱이 한다)
        do {
            let url = temporarySettingsURL().deletingLastPathComponent().appendingPathComponent("projects.json")
            write(shopJSON, to: url)
            let store = ProjectCatalogStore(url: url)
            let hadProjects = store.catalog.projects.count == 1

            try? FileManager.default.removeItem(at: url)
            let removed = store.reload()
            let backToDefault = store.catalog.projects.isEmpty && ProjectResolver.resolve(cwd: "/work/shop/api", catalog: store.catalog) == nil

            write("{ broken", to: url)
            let corrupt = store.reload()
            let corruptFileKept = (try? Data(contentsOf: url)) == Data("{ broken".utf8)

            write(#"{"schemaVersion":9,"projects":[]}"#, to: url)
            let unsupported = store.reload()

            results.append(
                check(
                    "재로딩: 파일 없음 → 기본 Dock, 손상·미래버전 → 적용 불가로 구분",
                    hadProjects && removed == .fresh && backToDefault
                        && corrupt == .corrupt && !corrupt.isUsable && corruptFileKept
                        && unsupported == .unsupportedVersion(found: 9) && !unsupported.isUsable,
                    "제거=\(removed.label) 기본Dock=\(backToDefault) 손상=\(corrupt.label)/보존=\(corruptFileKept) 미래=\(unsupported.label)"
                )
            )
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        // 4) 실패 후 정상 설정으로 복구
        do {
            let url = temporarySettingsURL().deletingLastPathComponent().appendingPathComponent("projects.json")
            write("{ broken", to: url)
            let store = ProjectCatalogStore(url: url)
            let failed = store.reload()
            write(shopJSON, to: url)
            let recovered = store.reload()
            let resolved = ProjectResolver.resolve(cwd: "/work/shop/api", catalog: store.catalog)

            results.append(
                check(
                    "재로딩: 실패 후 정상 설정으로 복구된다",
                    failed == .corrupt && recovered == .loaded && resolved?.projectID == "shop" && resolved?.links.count == 2,
                    "실패=\(failed.label) 복구=\(recovered.label) 프로젝트=\(resolved?.projectID ?? "-")"
                )
            )
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        // 5) 선택 유지 판정
        do {
            let base = ProjectCatalog(projects: [
                Project(id: "p", name: "P", root: "/work/p", links: [
                    ProjectLink(id: "one", name: "1", url: "https://example.com/1"),
                    ProjectLink(id: "two", name: "2", url: "https://example.com/2"),
                ])
            ])
            let same = ProjectResolver.resolve(cwd: "/work/p", catalog: base)
            let reordered = ProjectResolver.resolve(cwd: "/work/p", catalog: ProjectCatalog(projects: [
                Project(id: "p", name: "P", root: "/work/p", links: [
                    ProjectLink(id: "two", name: "2", url: "https://example.com/2"),
                    ProjectLink(id: "one", name: "1", url: "https://example.com/1"),
                ])
            ]))
            let urlChanged = ProjectResolver.resolve(cwd: "/work/p", catalog: ProjectCatalog(projects: [
                Project(id: "p", name: "P", root: "/work/p", links: [
                    ProjectLink(id: "one", name: "1", url: "https://example.com/1-changed"),
                    ProjectLink(id: "two", name: "2", url: "https://example.com/2"),
                ])
            ]))
            let shrunk = ProjectResolver.resolve(cwd: "/work/p", catalog: ProjectCatalog(projects: [
                Project(id: "p", name: "P", root: "/work/p", links: [
                    ProjectLink(id: "one", name: "1", url: "https://example.com/1"),
                ])
            ]))
            let renamedProject = ProjectResolver.resolve(cwd: "/work/p", catalog: ProjectCatalog(projects: [
                Project(id: "q", name: "Q", root: "/work/p", links: [
                    ProjectLink(id: "one", name: "1", url: "https://example.com/1"),
                    ProjectLink(id: "two", name: "2", url: "https://example.com/2"),
                ])
            ]))

            let keepsSame = ProjectSelection.selectionSurvives(reloadFrom: same, to: same)
            let dropsReordered = !ProjectSelection.selectionSurvives(reloadFrom: same, to: reordered)
            let dropsUrlChanged = !ProjectSelection.selectionSurvives(reloadFrom: same, to: urlChanged)
            let dropsShrunk = !ProjectSelection.selectionSurvives(reloadFrom: same, to: shrunk)
            let dropsOtherProject = !ProjectSelection.selectionSurvives(reloadFrom: same, to: renamedProject)
            let dropsNil = !ProjectSelection.selectionSurvives(reloadFrom: same, to: nil)

            results.append(
                check(
                    "재로딩: 링크 목록이 그대로면 선택 유지, 달라지면 선택 취소",
                    keepsSame && dropsReordered && dropsUrlChanged && dropsShrunk && dropsOtherProject && dropsNil,
                    "동일유지=\(keepsSame) 순서변경취소=\(dropsReordered) URL변경취소=\(dropsUrlChanged) 삭제취소=\(dropsShrunk) 프로젝트변경취소=\(dropsOtherProject) 없음=\(dropsNil)"
                )
            )
        }

        // 6) 선택 중 재로딩 → 다른 링크가 잘못 실행되지 않는다
        do {
            let before = ProjectResolution(
                projectID: "p", projectName: "P", projectRoot: "/work/p", matchedCWD: "/work/p",
                links: [
                    ProjectLinkTarget(projectID: "p", linkID: "one", name: "1", url: "https://example.com/1"),
                    ProjectLinkTarget(projectID: "p", linkID: "two", name: "2", url: "https://example.com/2"),
                ],
                diagnostics: []
            )
            // 재로딩 후 'one'이 사라지고 URL도 바뀐 구성
            let after = ProjectResolution(
                projectID: "p", projectName: "P", projectRoot: "/work/p", matchedCWD: "/work/p",
                links: [ProjectLinkTarget(projectID: "p", linkID: "two", name: "2", url: "https://example.com/2-changed")],
                diagnostics: []
            )
            let actionable = DockStateBuilder.make(
                current: workInfo(cwd: "/work/p", pathStatus: .valid, focusStatus: .tracked),
                previous: nil, connection: .connected, failure: nil, lock: DockLock()
            )
            let staleSelection = ProjectActionPlanner.plan(target: before.links[0], in: after, state: actionable)
            let alsoStale = ProjectActionPlanner.plan(target: before.links[1], in: after, state: actionable)

            results.append(
                check(
                    "재로딩: 선택 중 목록이 바뀌면 이전 선택이 실행되지 않는다",
                    staleSelection.rejectionReason != nil && alsoStale.rejectionReason != nil,
                    "삭제된링크=\(staleSelection.rejectionReason ?? "-") URL변경=\(alsoStale.rejectionReason ?? "-")"
                )
            )

            // 7) 로그용 URL 축약 — 토큰·쿼리를 남기지 않는다
            do {
                let withToken = ProjectLinkPrivacy.redactedForLog("https://user:pw@example.com/docs/page?token=SECRET#frag")
                let plain = ProjectLinkPrivacy.redactedForLog("https://example.com/a")
                let bad = ProjectLinkPrivacy.redactedForLog("not a url")
                results.append(
                    check(
                        "로그용 URL은 쿼리·프래그먼트·사용자정보를 제거한다",
                        withToken == "https://example.com/docs/page"
                            && plain == "https://example.com/a"
                            && bad == "<invalid-url>",
                        "토큰URL=\(withToken) 일반=\(plain) 잘못된값=\(bad)"
                    )
                )
            }
        }

        return results
    }

    private static func projectActionChecks(shop: Project, catalog: ProjectCatalog) -> [CheckResult] {
        var results: [CheckResult] = []

        let resolution = ProjectResolver.resolve(cwd: "/work/shop/api", catalog: catalog)
        let target = resolution?.links.first { $0.linkID == "repo" }
        let actionable = DockStateBuilder.make(
            current: workInfo(cwd: "/work/shop/api", pathStatus: .valid, focusStatus: .tracked),
            previous: nil, connection: .connected, failure: nil, lock: DockLock()
        )
        let errorState = DockStateBuilder.make(
            current: workInfo(cwd: "/work/shop/api", pathStatus: .missing, focusStatus: .unknown),
            previous: nil, connection: .connected, failure: nil, lock: DockLock()
        )
        let pendingState = DockStateBuilder.make(
            current: nil, previous: nil, connection: .unavailable, failure: "Ghostty is not running", lock: DockLock()
        )

        let allowed: Bool = {
            guard let target else { return false }
            if case .openURL(let url) = ProjectActionPlanner.plan(target: target, in: resolution, state: actionable) {
                return url.absoluteString == "https://example.com/shop/repo"
            }
            return false
        }()
        results.append(check("프로젝트 링크: 유효하면 URL로 연다(셸 문자열 없음)", allowed))

        var blockedCount = 0
        var reasons: [String] = []
        if let target {
            for state in [errorState, pendingState] {
                let plan = ProjectActionPlanner.plan(target: target, in: resolution, state: state)
                if plan.rejectionReason != nil { blockedCount += 1 }
                reasons.append(state.display.rawValue)
            }
        }
        results.append(
            check(
                "프로젝트 링크: 오류·확인 중에는 실행을 막는다",
                blockedCount == 2,
                "막힘=\(blockedCount)/2 상태=\(reasons)"
            )
        )

        // 선택 중 프로젝트가 바뀐 경우
        let otherResolution = ProjectResolver.resolve(cwd: "/work/shop/admin/src", catalog: catalog)
        var mismatchedRejected = false
        if let target {
            mismatchedRejected = ProjectActionPlanner.plan(target: target, in: otherResolution, state: actionable).rejectionReason != nil
        }
        // 링크가 사라진 경우
        var missingLinkRejected = false
        if let resolution {
            let stale = ProjectLinkTarget(projectID: shop.id, linkID: "gone", name: "사라진 링크", url: "https://example.com/gone")
            missingLinkRejected = ProjectActionPlanner.plan(target: stale, in: resolution, state: actionable).rejectionReason != nil
        }
        results.append(
            check(
                "프로젝트 링크: 프로젝트가 바뀌거나 링크가 사라지면 거부",
                mismatchedRejected && missingLinkRejected,
                "프로젝트변경=\(mismatchedRejected) 링크소멸=\(missingLinkRejected)"
            )
        )

        // 호출 중 동결이 오류를 숨기지 않는다
        let frozenError = DockStateBuilder.make(
            current: workInfo(cwd: "/work/shop/api", pathStatus: .valid, focusStatus: .tracked),
            previous: nil,
            connection: .unavailable,
            failure: "Ghostty is not running",
            lock: DockLock(),
            hostFrontmostOverride: true
        )
        let frozenInvalidPath = DockStateBuilder.make(
            current: workInfo(cwd: "/work/shop/gone", pathStatus: .missing, focusStatus: .unknown),
            previous: nil,
            connection: .connected,
            failure: nil,
            lock: DockLock(),
            hostFrontmostOverride: true
        )
        results.append(
            check(
                "호출 중 동결은 최전면 판정만 덮고 오류·경로 무효화는 그대로 드러낸다",
                frozenError.display == .error && frozenInvalidPath.display == .error,
                "연결오류=\(frozenError.display.rawValue) 경로무효=\(frozenInvalidPath.display.rawValue)"
            )
        )

        results.append(
            check(
                "동결로 유지 중이 된 경우에는 실행 가능하다(유지 중 = 유효한 대상)",
                {
                    let held = DockStateBuilder.make(
                        current: workInfo(cwd: "/work/shop/api", pathStatus: .valid, focusStatus: .held, frontmost: false),
                        previous: nil, connection: .connected, failure: nil, lock: DockLock(),
                        hostFrontmostOverride: true
                    )
                    return held.display == .tracked && held.isActionable
                }(),
                "동결 시 tracked로 복원"
            )
        )

        return results
    }

    // MARK: - 설정 저장·복원 (0.1b)

    private static func temporarySettingsURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-dock-selftest-\(UUID().uuidString)")
        return directory.appendingPathComponent("settings.json")
    }

    private static func settingsChecks() -> [CheckResult] {
        var results: [CheckResult] = []
        let fileManager = FileManager.default

        // 1. 파일 없음 → 기본값
        do {
            let url = temporarySettingsURL()
            let store = SettingsStore(url: url)
            results.append(
                check(
                    "설정: 파일 없음 → 기본값으로 시작",
                    store.outcome == .fresh
                        && store.settings.windowOrigin == nil
                        && store.settings.hotKey == .controlOptionCommandD
                        && store.settings.hotKeyEnabled
                        && !fileManager.fileExists(atPath: url.path),
                    "outcome=\(store.outcome) hotKey=\(store.settings.hotKey.rawValue) 파일생성=\(fileManager.fileExists(atPath: url.path))"
                )
            )
        }

        // 2. 저장 → 로드 왕복
        do {
            let url = temporarySettingsURL()
            let store = SettingsStore(url: url)
            store.update { settings in
                settings.windowOrigin = StoredOrigin(x: 123.5, y: -40.25)
                settings.hotKey = .controlOptionD
                settings.hotKeyEnabled = false
            }
            let reloaded = SettingsStore(url: url)
            let matched = reloaded.outcome == .loaded
                && reloaded.settings.windowOrigin == StoredOrigin(x: 123.5, y: -40.25)
                && reloaded.settings.hotKey == .controlOptionD
                && reloaded.settings.hotKeyEnabled == false
                && reloaded.settings.schemaVersion == PaneDockSettings.currentSchemaVersion
            results.append(
                check(
                    "설정: 저장 후 재로드 시 값이 유지된다(스키마 버전 포함)",
                    matched,
                    "outcome=\(reloaded.outcome) origin=\(reloaded.settings.windowOrigin.map { "\($0.x),\($0.y)" } ?? "-") hotKey=\(reloaded.settings.hotKey.rawValue) enabled=\(reloaded.settings.hotKeyEnabled) v=\(reloaded.settings.schemaVersion)"
                )
            )
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }

        // 3. 손상 파일 → 백업 보존 + 기본값
        do {
            let url = temporarySettingsURL()
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let garbage = Data("{ this is not json ".utf8)
            try? garbage.write(to: url)

            let store = SettingsStore(url: url)
            var backupMatches = false
            var backupPath = "-"
            if case .corrupt(let path) = store.outcome, let path {
                backupPath = path
                backupMatches = (try? Data(contentsOf: URL(fileURLWithPath: path))) == garbage
            }
            results.append(
                check(
                    "설정: 손상 파일은 원본을 백업으로 보존하고 기본값으로 시작",
                    backupMatches && store.settings.windowOrigin == nil && store.canWrite,
                    "backup=\(backupPath) 바이트보존=\(backupMatches) canWrite=\(store.canWrite)"
                )
            )
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }

        // 4. 미래 버전 → 파일을 건드리지 않는다
        do {
            let url = temporarySettingsURL()
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let future = Data(#"{"schemaVersion":9,"hotKey":"disabled","hotKeyEnabled":false}"#.utf8)
            try? future.write(to: url)

            let store = SettingsStore(url: url)
            let untouchedBefore = (try? Data(contentsOf: url)) == future
            // 저장을 시도해도 파일이 바뀌면 안 된다.
            store.update { $0.windowOrigin = StoredOrigin(x: 1, y: 2) }
            store.save()
            let untouchedAfter = (try? Data(contentsOf: url)) == future

            results.append(
                check(
                    "설정: 지원하지 않는 버전은 덮어쓰지 않는다",
                    store.outcome == .unsupportedVersion(found: 9)
                        && !store.canWrite
                        && untouchedBefore
                        && untouchedAfter,
                    "outcome=\(store.outcome) canWrite=\(store.canWrite) 로드후보존=\(untouchedBefore) 저장시도후보존=\(untouchedAfter)"
                )
            )
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }

        // 5. 메모리 전용 모드는 파일을 만들지 않는다(가짜 모드·자동 검사 경로)
        do {
            let store = SettingsStore(url: nil)
            store.update { $0.windowOrigin = StoredOrigin(x: 5, y: 5) }
            results.append(
                check(
                    "설정: 메모리 전용 모드는 파일을 만들지 않는다",
                    store.isMemoryOnly && store.fileURL == nil && store.settings.windowOrigin == StoredOrigin(x: 5, y: 5),
                    "isMemoryOnly=\(store.isMemoryOnly) origin=\(store.settings.windowOrigin.map { "\($0.x),\($0.y)" } ?? "-")"
                )
            )
        }

        // 6. 저장 스키마에 pane·경로·잠금이 들어가지 않는다
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(PaneDockSettings())) ?? Data()
            let json = String(decoding: data, as: UTF8.self).lowercased()
            let forbidden = ["paneid", "pane_id", "reportedcwd", "path", "lock", "locked"]
            let found = forbidden.filter { json.contains($0) }
            results.append(
                check(
                    "설정 스키마에 pane ID·경로·잠금 상태가 없다",
                    found.isEmpty,
                    found.isEmpty ? json : "발견: \(found.joined(separator: ","))"
                )
            )
        }

        // 7. 창 좌표 보정
        do {
            let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let secondary = CGRect(x: 1920, y: 0, width: 1280, height: 800)
            let size = CGSize(width: 360, height: 260)
            let fallback = CGRect(x: 0, y: 0, width: 1920, height: 1000)

            let insideMain = WindowPlacement.clamp(origin: CGPoint(x: 100, y: 100), size: size, screens: [main, secondary], fallback: fallback)
            let insideSecondary = WindowPlacement.clamp(origin: CGPoint(x: 2000, y: 200), size: size, screens: [main, secondary], fallback: fallback)
            let offScreen = WindowPlacement.clamp(origin: CGPoint(x: 90000, y: 90000), size: size, screens: [main, secondary], fallback: fallback)
            let disconnected = WindowPlacement.clamp(origin: CGPoint(x: 2000, y: 200), size: size, screens: [main], fallback: fallback)
            let noScreens = WindowPlacement.clamp(origin: CGPoint(x: 500, y: 500), size: size, screens: [], fallback: fallback)

            let offScreenIsVisible = fallback.contains(CGRect(origin: offScreen, size: size))
            let disconnectedIsVisible = fallback.contains(CGRect(origin: disconnected, size: size))
            let noScreensIsVisible = fallback.contains(CGRect(origin: noScreens, size: size))

            results.append(
                check(
                    "창 좌표: 화면 안 좌표는 유지, 화면 밖 좌표는 보이는 위치로 보정",
                    insideMain == CGPoint(x: 100, y: 100)
                        && insideSecondary == CGPoint(x: 2000, y: 200)
                        && offScreenIsVisible && disconnectedIsVisible && noScreensIsVisible,
                    "main=\(insideMain) secondary=\(insideSecondary) offScreen보정=\(offScreenIsVisible) 연결끊김보정=\(disconnectedIsVisible) 화면없음보정=\(noScreensIsVisible)"
                )
            )

            let defaultOrigin = WindowPlacement.defaultOrigin(in: fallback)
            results.append(
                check(
                    "창 좌표: 기본 위치가 기준 화면 안쪽이다",
                    fallback.contains(CGRect(origin: defaultOrigin, size: size)),
                    "default=\(defaultOrigin)"
                )
            )
        }

        return results
    }

    // MARK: - Dock 상태·잠금·실행 계획 (앱과 공유하는 로직)

    private static func workInfo(
        pane: String = "term-A",
        cwd: String?,
        pathStatus: PathStatus,
        focusStatus: FocusStatus,
        frontmost: Bool? = true
    ) -> CurrentWorkInfo {
        CurrentWorkInfo(
            identity: PaneIdentity(
                adapterID: GhosttyAdapter.adapterID,
                hostAppID: "ghostty",
                machineID: "local",
                workspaceID: "win-1",
                tabID: "tab-1",
                paneID: pane,
                terminalID: pane
            ),
            reportedCWD: cwd,
            normalizedCWD: cwd.map(PathNormalizer.normalize),
            cwdSource: .ghosttyWorkingDirectory,
            observedAt: now,
            focusGeneration: 1,
            focusStatus: focusStatus,
            pathStatus: pathStatus,
            connectionStatus: .connected,
            hostFrontmost: frontmost
        )
    }

    private static func dockChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        let tracked = workInfo(cwd: "/work/a", pathStatus: .valid, focusStatus: .tracked)
        let held = workInfo(cwd: "/work/a", pathStatus: .valid, focusStatus: .held, frontmost: false)
        let pending = workInfo(cwd: nil, pathStatus: .pending, focusStatus: .pending)
        let missing = workInfo(cwd: "/work/gone", pathStatus: .missing, focusStatus: .unknown)

        // 화면 상태 파생 5종
        let none = DockLock()
        let cases: [(String, DockState)] = [
            ("추적 중", DockStateBuilder.make(current: tracked, previous: nil, connection: .connected, failure: nil, lock: none)),
            ("유지 중", DockStateBuilder.make(current: held, previous: tracked, connection: .connected, failure: nil, lock: none)),
            ("확인 중", DockStateBuilder.make(current: pending, previous: tracked, connection: .connected, failure: nil, lock: none)),
            ("오류(경로 없음)", DockStateBuilder.make(current: missing, previous: tracked, connection: .connected, failure: nil, lock: none)),
            ("오류(연결 끊김)", DockStateBuilder.make(current: tracked, previous: nil, connection: .unavailable, failure: "Ghostty is not running", lock: none)),
        ]
        let expected: [DockDisplayState] = [.tracked, .held, .pending, .error, .error]
        for (index, entry) in cases.enumerated() {
            results.append(
                check(
                    "화면 상태: \(entry.0)",
                    entry.1.display == expected[index],
                    "\(entry.1.display.rawValue)\(entry.1.detail.map { " / \($0)" } ?? "")"
                )
            )
        }

        results.append(
            check(
                "연결이 끊기면 마지막 경로를 유효한 대상으로 표시하지 않는다",
                cases[4].1.display == .error && cases[4].1.detail == "Ghostty is not running",
                "display=\(cases[4].1.display.rawValue) detail=\(cases[4].1.detail ?? "-")"
            )
        )

        // 유지 중에도 이전 위치를 별도로 남긴다
        results.append(
            check(
                "유지 중에 이전 위치를 분리해 표시",
                cases[1].1.fullPath == "/work/a" && cases[1].1.previousPath == "/work/a",
                "path=\(cases[1].1.fullPath ?? "-") previous=\(cases[1].1.previousPath ?? "-")"
            )
        )

        // 버튼 활성화는 표시 상태와 일치해야 한다(오류·확인 중에는 실행할 대상이 확정되지 않았다).
        var lockedLock = DockLock()
        lockedLock.lock(tracked)
        let lockedForActionability = DockStateBuilder.make(
            current: tracked,
            previous: nil,
            connection: .connected,
            failure: nil,
            lock: lockedLock
        )
        let actionability: [(String, Bool)] = [
            ("추적 중", cases[0].1.canOpenFolder && cases[0].1.canCopyPath),
            ("유지 중", cases[1].1.canOpenFolder && cases[1].1.canCopyPath),
            ("확인 중", !cases[2].1.canOpenFolder && !cases[2].1.canCopyPath),
            ("오류(경로 없음)", !cases[3].1.canOpenFolder && !cases[3].1.canCopyPath),
            ("오류(연결 끊김·경로 잔존)", !cases[4].1.canOpenFolder && !cases[4].1.canCopyPath),
            ("잠금(유효 대상)", lockedForActionability.canOpenFolder && lockedForActionability.canCopyPath),
        ]
        let buttonStates = [
            ("tracked", cases[0].1),
            ("held", cases[1].1),
            ("pending", cases[2].1),
            ("error/no-path", cases[3].1),
            ("error/lost-connection", cases[4].1),
            ("locked", lockedForActionability),
        ]
        results.append(
            check(
                "버튼 활성화가 표시 상태와 일치한다",
                actionability.allSatisfy { $0.1 },
                buttonStates
                    .map { "\($0.0): open=\($0.1.canOpenFolder) copy=\($0.1.canCopyPath)" }
                    .joined(separator: " | ")
            )
        )

        // F: 잠금 → 새 후보가 와도 표시가 고정된다
        var lock = DockLock()
        lock.lock(tracked)
        let other = workInfo(pane: "term-B", cwd: "/work/b", pathStatus: .valid, focusStatus: .tracked)
        let lockedState = DockStateBuilder.make(current: other, previous: tracked, connection: .connected, failure: nil, lock: lock)

        // G: 잠금 해제 → 현재 값으로 돌아온다
        lock.unlock()
        let unlockedState = DockStateBuilder.make(current: other, previous: tracked, connection: .connected, failure: nil, lock: lock)

        results.append(
            check(
                "F: 잠금 중에는 새 후보로 바뀌지 않는다",
                lockedState.display == .locked && lockedState.fullPath == "/work/a" && lockedState.isLocked,
                "display=\(lockedState.display.rawValue) path=\(lockedState.fullPath ?? "-")"
            )
        )
        results.append(
            check(
                "G: 잠금 해제 시 현재 대상이 반영된다",
                unlockedState.display == .tracked && unlockedState.fullPath == "/work/b" && !unlockedState.isLocked,
                "display=\(unlockedState.display.rawValue) path=\(unlockedState.fullPath ?? "-")"
            )
        )

        // 잠긴 대상이 무효해지면 잠금이라도 오류로 표시한다
        var brokenLock = DockLock()
        brokenLock.lock(missing)
        let brokenState = DockStateBuilder.make(current: tracked, previous: nil, connection: .connected, failure: nil, lock: brokenLock)
        results.append(
            check(
                "잠긴 대상의 경로가 사라지면 오류로 표시",
                brokenState.display == .error,
                "display=\(brokenState.display.rawValue) detail=\(brokenState.detail ?? "-")"
            )
        )

        // 실행 계획
        let planner = StubValidator(directories: ["/work/a"])
        let openValid = DockActionPlanner.plan(.openFolder, for: tracked, validator: planner)
        let openMissing = DockActionPlanner.plan(.openFolder, for: missing, validator: planner)
        let openNone = DockActionPlanner.plan(.openFolder, for: nil, validator: planner)
        let copyValid = DockActionPlanner.plan(.copyPath, for: tracked, validator: planner)

        let openValidOK: Bool = {
            if case .openFolder(let url) = openValid { return url.path == "/work/a" }
            return false
        }()
        let copyOK: Bool = {
            if case .copyPath(let path) = copyValid { return path == "/work/a" }
            return false
        }()

        results.append(
            check(
                "실행 계획: 유효 경로는 URL/문자열로만 만든다(셸 문자열 없음)",
                openValidOK && copyOK,
                "open=\(openValid) copy=\(copyValid)"
            )
        )
        results.append(
            check(
                "H: 없는 경로·대상 없음은 실행을 거부한다",
                openMissing.rejectionReason != nil && openNone.rejectionReason != nil,
                "missing=\(openMissing.rejectionReason ?? "-") none=\(openNone.rejectionReason ?? "-")"
            )
        )

        // 클릭 시점 스냅샷: 이후 상태가 바뀌어도 계획은 그대로다
        let clickTimePlan = DockActionPlanner.plan(.copyPath, for: tracked, validator: planner)
        let afterUpdatePlan = DockActionPlanner.plan(.copyPath, for: other, validator: planner)
        results.append(
            check(
                "클릭 시점 값으로 고정된 계획은 이후 갱신에 흔들리지 않는다",
                clickTimePlan == .copyPath("/work/a") && afterUpdatePlan == .copyPath("/work/b"),
                "click=\(clickTimePlan) later=\(afterUpdatePlan)"
            )
        )

        results.append(
            check(
                "폴더 이름 추출",
                DockStateBuilder.folderName(of: "/work/shop/api") == "api"
                    && DockStateBuilder.folderName(of: nil) == "-"
                    && DockStateBuilder.folderName(of: "/") == "/",
                "api=\(DockStateBuilder.folderName(of: "/work/shop/api")) nil=\(DockStateBuilder.folderName(of: nil))"
            )
        )

        return results
    }

    private static func ghosttyErrorChecks() -> [CheckResult] {
        let cases: [(String, Int, TerminalHostQueryError, ConnectionStatus)] = [
            ("앱 미실행", -600, .notRunning, .unavailable),
            ("자동화 권한 거부", -1743, .automationDenied, .denied),
            ("AppleScript 미지원", -1708, .appleScriptUnsupported, .incompatible),
            ("창 없음", -1728, .noWindow, .connected),
        ]
        return cases.map { label, code, expected, status in
            let classified = TerminalHostQueryError.classify(
                stderr: "execution error: Ghostty got an error: something. (\(code))",
                status: 1
            )
            return check(
                "오류 분류: \(label)",
                classified == expected && classified.connectionStatus == status,
                "\(classified) / \(classified.connectionStatus.rawValue)"
            )
        }
    }

    private static func ghosttyParseChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        do {
            let snapshot = try TerminalHostPayload.parse(
                hostOutput(focused: "term-B", terminals: [
                    (window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?),
                    (window: "win-1", tab: "tab-2", id: "term-B", wd: "/work/b", name: "b" as String?),
                ])
            )
            let targetIsFocused = snapshot.target?.terminalID == "term-B"
            let targetTab = snapshot.target?.tabID == "tab-2"
            results.append(
                check(
                    "파싱: focused terminal이 대상이 된다",
                    snapshot.version == "1.3.1" && targetIsFocused && targetTab && snapshot.terminals.count == 2,
                    "version=\(snapshot.version ?? "-") target=\(snapshot.target?.terminalID ?? "-") tab=\(snapshot.target?.tabID ?? "-") n=\(snapshot.terminals.count)"
                )
            )
        } catch {
            results.append(check("파싱: focused terminal이 대상이 된다", false, "\(error)"))
        }

        do {
            _ = try TerminalHostPayload.parse("notRunning=true\n")
            results.append(check("파싱: 미실행 응답 거부", false, "오류가 나지 않았다"))
        } catch let failure as TerminalHostQueryError {
            results.append(check("파싱: 미실행 응답 거부", failure == .notRunning, "\(failure)"))
        } catch {
            results.append(check("파싱: 미실행 응답 거부", false, "\(error)"))
        }

        results.append(
            check(
                "버전 게이트: AppleScript 1.3.0+",
                GhosttyAdapter.compareVersions("1.2.9", "1.3.0") < 0
                    && GhosttyAdapter.compareVersions("1.3.0", "1.3.0") == 0
                    && GhosttyAdapter.compareVersions("1.3.1", "1.3.0") > 0,
                "1.2.9<1.3.0<1.3.1 비교"
            )
        )

        return results
    }

    // MARK: - cmux (실험 경로)

    /// cmux는 **소켓(공식 CLI)** 으로 조회한다. AppleScript는 사전이 있어도 객체 모델이 응답하지
    /// 않아 쓸 수 없다(V11 실측: `count of windows`, `working directory of terminal 1` 모두 타임아웃).
    ///
    /// 여기서는 그 조회 결과를 합성해 **공통 반영 경로**를 지나간다.
    /// **이것은 합성 검사다.** 실제 cmux 관측은 `docs/verification.md` V11에 따로 기록하며,
    /// 여기 통과를 실제 동작 확인으로 승격하지 않는다.

    private final class StubCmuxQueries: CmuxQuerying, @unchecked Sendable {
        private var identifies: [CmuxIdentify]
        private var sidebars: [CmuxSidebarState]
        private let failure: CmuxQueryError?
        private(set) var queriedWorkspaces: [String] = []

        init(identifies: [CmuxIdentify] = [], sidebars: [CmuxSidebarState] = [], failure: CmuxQueryError? = nil) {
            self.identifies = identifies
            self.sidebars = sidebars
            self.failure = failure
        }

        func identify() throws -> CmuxIdentify {
            if let failure { throw failure }
            guard !identifies.isEmpty else { throw CmuxQueryError.malformed("identify stub exhausted") }
            return identifies.removeFirst()
        }

        func sidebarState(workspaceID: String) throws -> CmuxSidebarState {
            queriedWorkspaces.append(workspaceID)
            if let failure { throw failure }
            guard !sidebars.isEmpty else { throw CmuxQueryError.malformed("sidebar stub exhausted") }
            return sidebars.removeFirst()
        }
    }

    private final class StubFrontmostApp: FrontmostAppChecking, @unchecked Sendable {
        var bundleIdentifier: String?

        init(_ bundleIdentifier: String?) {
            self.bundleIdentifier = bundleIdentifier
        }

        func frontmostBundleIdentifier() -> String? { bundleIdentifier }
    }

    /// cmux의 4단계(window → workspace → pane → surface)를 그대로 담는다.
    private static func cmuxFocus(
        workspace: String,
        surface: String,
        pane: String = "pane-1",
        type: String = "terminal",
        browser: Bool = false
    ) -> CmuxFocused {
        CmuxFocused(
            windowID: "win-1",
            workspaceID: workspace,
            paneID: pane,
            surfaceID: surface,
            tabID: surface,
            surfaceType: type,
            isBrowserSurface: browser
        )
    }

    private static func cmuxIdentify(_ focused: CmuxFocused?, caller: String? = nil) -> CmuxIdentify {
        CmuxIdentify(caller: caller, focused: focused)
    }

    private static func cmuxSidebar(cwd: String?, focusedCWD: String?, panel: String?) -> CmuxSidebarState {
        CmuxSidebarState(cwd: cwd, focusedCWD: focusedCWD, focusedPanel: panel)
    }

    private static func cmuxChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        // A: workspace A → B 전환. 새 workspace·surface 식별자와 새 경로가 함께 바뀐다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a", "/work/b"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-2", surface: "panel-B", pane: "pane-2")),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/work/b", focusedCWD: "/work/b", panel: "panel-B"),
                ]
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let first = "\(store.current?.identity.tabID ?? "-")/\(store.current?.identity.paneID ?? "-")/\(store.current?.reportedCWD ?? "-")"
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let second = "\(store.current?.identity.tabID ?? "-")/\(store.current?.identity.paneID ?? "-")/\(store.current?.reportedCWD ?? "-")"
            let sourceIsCmux = store.current?.cwdSource == .cmuxFocusedCWD
                && store.current?.identity.adapterID == CmuxAdapter.adapterID
                && store.current?.identity.hostAppID == "cmux"
            results.append(
                check(
                    "cmux A: workspace 전환 시 새 식별자와 새 경로",
                    first == "ws-1/panel-A//work/a" && second == "ws-2/panel-B//work/b" && sourceIsCmux,
                    "\(first) → \(second) source=\(store.current?.cwdSource?.rawValue ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux A: workspace 전환 시 새 식별자와 새 경로", false, "\(error)"))
        }

        // B: 같은 surface에서 cd. 식별자는 유지되고 경로만 갱신된다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a", "/work/c"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/c", panel: "panel-A"),
                ]
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let paneBefore = store.current?.identity.paneID
            let pathBefore = store.current?.reportedCWD
            let generationBefore = store.focusGeneration
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "cmux B: 같은 surface에서 cd는 식별자를 유지하고 경로만 갱신",
                    paneBefore == "panel-A" && pathBefore == "/work/a"
                        && store.current?.identity.paneID == "panel-A"
                        && store.current?.reportedCWD == "/work/c"
                        && store.focusGeneration == generationBefore
                        && store.previous == nil,
                    "\(paneBefore ?? "-")/\(pathBefore ?? "-") → \(store.current?.reportedCWD ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux B: 같은 surface에서 cd는 식별자를 유지하고 경로만 갱신", false, "\(error)"))
        }

        // 요약 경로 함정: workspace 요약 cwd가 달라도 표시 경로는 focused_cwd를 따른다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a", "/summary"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/summary", focusedCWD: "/work/a", panel: "panel-A"),
                ]
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "cmux: workspace 요약 cwd를 surface 경로로 쓰지 않는다",
                    store.current?.reportedCWD == "/work/a" && store.current?.cwdSource == .cmuxFocusedCWD,
                    "path=\(store.current?.reportedCWD ?? "nil") source=\(store.current?.cwdSource?.rawValue ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux: workspace 요약 cwd를 surface 경로로 쓰지 않는다", false, "\(error)"))
        }

        // C: 비활성 panel은 아예 조회하지 않는다 → 표시가 바뀔 수 없다.
        do {
            let (adapter, _, _, _) = makeCmuxStore(
                directories: ["/work/a"],
                identifies: [cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A"))],
                sidebars: [cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A")]
            )
            let snapshot = try adapter.snapshot()
            results.append(
                check(
                    "cmux C: 비활성 panel을 조회하지 않으므로 배경 경로가 표시를 바꿀 수 없다",
                    adapter.records(in: snapshot).isEmpty && snapshot.terminals.count == 1,
                    "terminals=\(snapshot.terminals.count) background=\(adapter.records(in: snapshot).count)"
                )
            )
        } catch {
            results.append(check("cmux C: 비활성 panel을 조회하지 않으므로 배경 경로가 표시를 바꿀 수 없다", false, "\(error)"))
        }

        // D: 전환 전 surface에 대한 늦은 응답은 버려진다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a", "/work/b"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-2", surface: "panel-B", pane: "pane-2")),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/work/b", focusedCWD: "/work/b", panel: "panel-B"),
                ]
            )
            let firstSnapshot = try adapter.snapshot()
            let firstRecord = adapter.focusedRecord(in: firstSnapshot)
            TerminalHostSnapshotApplier.apply(firstSnapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let staleGeneration = store.focusGeneration
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let late = firstRecord.map { store.apply(PaneObservation(generation: staleGeneration, record: $0)) }
            results.append(
                check(
                    "cmux D: 전환 전 surface의 늦은 응답은 최종 선택을 덮어쓰지 않는다",
                    late == .discardedStale
                        && store.current?.identity.paneID == "panel-B"
                        && store.current?.reportedCWD == "/work/b",
                    "outcome=\(late.map(String.init(describing:)) ?? "nil") current=\(store.current?.identity.paneID ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux D: 전환 전 surface의 늦은 응답은 최종 선택을 덮어쓰지 않는다", false, "\(error)"))
        }

        // E: cmux가 최전면이 아니면 마지막으로 확인한 대상을 "유지 중"으로 구분한다.
        do {
            let frontmost = StubFrontmostApp(CmuxAdapter.bundleIdentifier)
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                ],
                frontmost: frontmost
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let wasTracked = store.current?.focusStatus == .tracked
            // 다른 앱이 최전면이 된다(판정 가능하지만 cmux가 아니다).
            frontmost.bundleIdentifier = "com.example.other"
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "cmux E: 최전면이 아니면 마지막으로 확인한 대상을 유지 중으로 구분한다",
                    wasTracked && store.current?.focusStatus == .held
                        && store.current?.reportedCWD == "/work/a"
                        && store.current?.hostFrontmost == false,
                    "tracked=\(wasTracked) focus=\(store.current?.focusStatus.rawValue ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux E: 최전면이 아니면 마지막으로 확인한 대상을 유지 중으로 구분한다", false, "\(error)"))
        }

        // E-2: 최전면을 **판정할 수 없으면** "유지 중"으로 단정하지 않는다.
        // (TTY 없이 분리 실행된 프로세스에서 실제로 발생한 문맥이다 — V11)
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a"],
                identifies: [cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A"))],
                sidebars: [cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A")],
                frontmost: StubFrontmostApp(nil)
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "cmux E: 최전면을 판정할 수 없으면 추적 중으로 승격하지 않는다",
                    store.current?.focusStatus == .unknown && store.current?.hostFrontmost == nil
                        && store.current?.reportedCWD == "/work/a"
                        && store.current?.pathStatus == .valid,
                    "focus=\(store.current?.focusStatus.rawValue ?? "-") hostFrontmost=\(store.current?.hostFrontmost.map(String.init) ?? "nil")"
                )
            )
        } catch {
            results.append(check("cmux E: 최전면을 판정할 수 없으면 추적 중으로 승격하지 않는다", false, "\(error)"))
        }

        // F-1: 포커스된 panel이 터미널이 아니면 이전 경로를 현재 대상처럼 남기지 않는다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/a"],
                identifies: [
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A")),
                    cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "browser-A", type: "browser", browser: true)),
                ],
                sidebars: [
                    cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/a", panel: "panel-A"),
                    cmuxSidebar(cwd: "/work/a", focusedCWD: nil, panel: "browser-A"),
                ]
            )
            let firstSnapshot = try adapter.snapshot()
            let firstRecord = adapter.focusedRecord(in: firstSnapshot)
            TerminalHostSnapshotApplier.apply(firstSnapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let generationBefore = store.focusGeneration
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let reason = store.lastFailure ?? ""
            results.append(
                check(
                    "cmux F: 터미널이 아닌 panel로 가면 이전 경로를 현재 대상처럼 남기지 않는다",
                    store.current?.reportedCWD == nil && store.current?.pathStatus == .pending
                        && store.current?.identity.paneID == "-"
                        && store.previous?.reportedCWD == "/work/a"
                        && reason.contains("not a terminal"),
                    "current=\(store.current?.identity.paneID ?? "-")/\(store.current?.reportedCWD ?? "nil") previous=\(store.previous?.reportedCWD ?? "nil")"
                )
            )
            if let firstRecord {
                let late = store.apply(PaneObservation(generation: generationBefore, record: firstRecord))
                results.append(
                    check(
                        "cmux F: 터미널이 아닌 panel로 간 뒤 이전 대상의 늦은 응답이 되살아나지 않는다",
                        late == .discardedStale && store.current?.reportedCWD == nil,
                        "outcome=\(late) current=\(store.current?.reportedCWD ?? "nil")"
                    )
                )
            }
        } catch {
            results.append(check("cmux F: 터미널이 아닌 panel로 가면 이전 경로를 현재 대상처럼 남기지 않는다", false, "\(error)"))
        }

        // F-2: focused_panel이 선택된 surface와 다르면 그 경로를 인정하지 않는다.
        do {
            let (adapter, store, resolver, validator) = makeCmuxStore(
                directories: ["/work/other"],
                identifies: [cmuxIdentify(cmuxFocus(workspace: "ws-1", surface: "panel-A"))],
                sidebars: [cmuxSidebar(cwd: "/work/a", focusedCWD: "/work/other", panel: "panel-Z")]
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "cmux F: focused_panel이 선택된 surface와 다르면 경로를 인정하지 않는다",
                    store.current?.reportedCWD == nil && store.current?.pathStatus == .unsupported
                        && store.current?.cwdSource == nil,
                    "path=\(store.current?.reportedCWD ?? "nil") validity=\(store.current?.pathStatus.rawValue ?? "-")"
                )
            )
        } catch {
            results.append(check("cmux F: focused_panel이 선택된 surface와 다르면 경로를 인정하지 않는다", false, "\(error)"))
        }

        // F-3: 연결 실패는 경로 없이 구분하고, 사유는 cmux라고 말한다.
        do {
            let probe = GhosttyProbe(
                adapter: CmuxAdapter(client: StubCmuxQueries(failure: .notRunning), frontmost: StubFrontmostApp(nil)),
                validator: StubValidator(directories: [])
            )
            probe.refresh()
            let failure = probe.store.lastFailure ?? ""
            results.append(
                check(
                    "cmux F: 연결 실패는 경로 없이 구분하고 사유에 cmux라고 표시한다",
                    probe.store.connection == .unavailable && probe.store.current == nil
                        && failure.contains("cmux") && !failure.contains("Ghostty"),
                    "connection=\(probe.store.connection.rawValue) failure=\(failure)"
                )
            )
        }

        // F-4: 해석할 수 없는 응답을 경로로 바꾸지 않는다.
        do {
            var rejected = false
            do {
                _ = try CmuxIdentify.parse(Data("not json".utf8))
            } catch {
                rejected = true
            }
            let empty = CmuxSidebarState.parse("cwd=/work/a\nfocused_cwd=none\nfocused_panel=\n")
            results.append(
                check(
                    "cmux: 해석할 수 없는 응답과 빈 값을 경로로 만들지 않는다",
                    rejected && empty.focusedCWD == nil && empty.focusedPanel == nil && empty.cwd == "/work/a",
                    "rejected=\(rejected) focused_cwd=\(empty.focusedCWD ?? "nil") panel=\(empty.focusedPanel ?? "nil")"
                )
            )
        }

        // 회귀: Ghostty는 이 신호를 주지 않으므로 새 규칙이 Ghostty의 대상을 지우면 안 된다.
        do {
            let panel = [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?)]
            let (adapter, store, resolver, validator) = makeGhosttyStore(
                directories: ["/work/a"],
                outputs: [
                    hostOutput(focused: "term-A", terminals: panel),
                    hostOutput(frontWindow: "win-9", selectedTab: "tab-9", focused: nil, terminals: panel),
                ]
            )
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            results.append(
                check(
                    "회귀: Ghostty는 대상이 없어도 새 규칙으로 대상을 지우지 않는다",
                    store.current?.identity.paneID == "term-A" && store.current?.reportedCWD == "/work/a"
                        && store.targetPaneID == "term-A",
                    "current=\(store.current?.identity.paneID ?? "-")/\(store.current?.reportedCWD ?? "nil")"
                )
            )
        } catch {
            results.append(check("회귀: Ghostty는 대상이 없어도 새 규칙으로 대상을 지우지 않는다", false, "\(error)"))
        }

        return results
    }

    // MARK: - 여러 호스트 라우팅 (V12)

    /// 라우터 검사용 Adapter. **조회 횟수를 세어** "고른 호스트만 조회했는지"를 확인한다.
    private final class StubHostAdapter: TerminalHostAdapter, @unchecked Sendable {
        let stubName: String
        private let paneID: String
        private let tabID: String
        private var path: String?
        private let source: CWDSource
        private let failure: TerminalHostQueryError?
        private(set) var queryCount = 0

        /// 같은 panel에서 경로가 바뀐 상황을 만든다.
        func setPath(_ newPath: String?) {
            path = newPath
        }

        init(
            name: String,
            paneID: String,
            tabID: String = "ws-1",
            path: String? = "/work/a",
            source: CWDSource = .ghosttyWorkingDirectory,
            failure: TerminalHostQueryError? = nil
        ) {
            self.stubName = name
            self.paneID = paneID
            self.tabID = tabID
            self.path = path
            self.source = source
            self.failure = failure
        }

        var appName: String { stubName }
        var appleScriptRequirement: String? { nil }

        var factory: WorkInfoFactory {
            WorkInfoFactory(adapterID: stubName, hostAppID: stubName, machineID: "local", defaultCWDSource: source)
        }

        func unsupportedVersionReason(_ version: String?) -> String? { nil }

        /// 비터미널 panel(브라우저 등)을 흉내 낼 때 false로 둔다.
        var isTerminalPanel = true

        func snapshot() throws -> TerminalHostSnapshot {
            queryCount += 1
            if let failure { throw failure }
            let terminals = isTerminalPanel
                ? [
                    TerminalHostTerminal(
                        terminalID: paneID,
                        windowID: "win-1",
                        tabID: tabID,
                        workingDirectory: path,
                        name: nil
                    )
                ]
                : []
            return TerminalHostSnapshot(
                version: nil,
                frontmost: true,
                frontWindowID: "win-1",
                selectedTabID: tabID,
                focusedTerminalID: paneID,
                focusedWorkingDirectory: isTerminalPanel ? path : nil,
                focusedPanelIsTerminal: isTerminalPanel,
                terminals: terminals
            )
        }

        func focusedRecord(in snapshot: TerminalHostSnapshot) -> PaneRecord? {
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
                title: nil
            )
        }

        func records(in snapshot: TerminalHostSnapshot) -> [PaneRecord] { [] }

        func noTargetReason(in snapshot: TerminalHostSnapshot) -> String {
            isTerminalPanel ? "no target (\(stubName))" : "focused panel is not a terminal (\(stubName))"
        }
    }

    /// 최전면 앱을 바꿀 수 있는 checker.
    private static func makeRouter(
        ghostty: StubHostAdapter,
        cmux: StubHostAdapter,
        frontmost: StubFrontmostApp
    ) -> TerminalHostRouter {
        TerminalHostRouter(
            hosts: [
                TerminalHostRouter.Host(adapter: ghostty, bundleIdentifier: "com.mitchellh.ghostty"),
                TerminalHostRouter.Host(adapter: cmux, bundleIdentifier: "com.cmuxterm.app"),
            ],
            frontmost: frontmost
        )
    }

    private static func hostRouterChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        // 최전면 앱을 따라가고, **고른 호스트만** 조회한다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp("com.mitchellh.ghostty")
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)

            let first = try router.snapshot()
            frontmost.bundleIdentifier = "com.cmuxterm.app"
            let second = try router.snapshot()

            results.append(
                check(
                    "라우터: 최전면 호스트를 따르고 고른 호스트만 조회한다",
                    router.currentHostName == "cmux"
                        && first.target?.terminalID == "term-A"
                        && second.target?.terminalID == "panel-B"
                        && ghostty.queryCount == 1
                        && cmux.queryCount == 1,
                    "ghostty=\(ghostty.queryCount)회 cmux=\(cmux.queryCount)회 chosen=\(router.currentHostName)"
                )
            )
        } catch {
            results.append(check("라우터: 최전면 호스트를 따르고 고른 호스트만 조회한다", false, "\(error)"))
        }

        // 둘 다 뒤에 있으면 **마지막 호스트를 유지**한다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp("com.cmuxterm.app")
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)

            _ = try router.snapshot()
            frontmost.bundleIdentifier = "com.example.other"   // 둘 다 최전면이 아니다
            _ = try router.snapshot()

            results.append(
                check(
                    "라우터: 둘 다 최전면이 아니면 마지막 호스트를 유지한다",
                    router.currentHostName == "cmux" && cmux.queryCount == 2 && ghostty.queryCount == 0,
                    "chosen=\(router.currentHostName) cmux=\(cmux.queryCount)회 ghostty=\(ghostty.queryCount)회"
                )
            )
        } catch {
            results.append(check("라우터: 둘 다 최전면이 아니면 마지막 호스트를 유지한다", false, "\(error)"))
        }

        // 판정할 수 없으면(nil) "최전면 아님"으로 단정하지 않고 기본·마지막 규칙으로 내려간다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp(nil)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)

            let initial = router.currentHostName
            _ = try router.snapshot()
            frontmost.bundleIdentifier = "com.cmuxterm.app"
            _ = try router.snapshot()
            frontmost.bundleIdentifier = nil
            _ = try router.snapshot()

            results.append(
                check(
                    "라우터: 최전면을 판정할 수 없으면 기본 호스트로 시작하고 이후에는 마지막을 유지한다",
                    initial == "ghostty" && router.currentHostName == "cmux",
                    "initial=\(initial) after=\(router.currentHostName)"
                )
            )
        } catch {
            results.append(check("라우터: 최전면을 판정할 수 없으면 기본 호스트로 시작하고 이후에는 마지막을 유지한다", false, "\(error)"))
        }

        // 고른 호스트의 실패를 숨기지 않는다 — 조용히 다른 호스트로 갈아타지 않는다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(
                name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD, failure: .notRunning
            )
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: StubFrontmostApp("com.cmuxterm.app"))
            let probe = GhosttyProbe(adapter: router, validator: StubValidator(directories: ["/work/a", "/work/b"]))
            probe.refresh()
            let failure = probe.store.lastFailure ?? ""

            results.append(
                check(
                    "라우터: 고른 호스트의 실패를 숨기지 않고 다른 호스트로 갈아타지 않는다",
                    probe.store.connection == .unavailable
                        && ghostty.queryCount == 0
                        && failure.contains("cmux")
                        && !failure.contains("Ghostty"),
                    "connection=\(probe.store.connection.rawValue) ghostty조회=\(ghostty.queryCount)회 failure=\(failure)"
                )
            )
        }

        // 호스트가 바뀌면 **신원과 경로 출처가 함께** 바뀐다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp("com.mitchellh.ghostty")
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)
            let (adapter, store, resolver, validator) = makeHostStore(router, directories: ["/work/a", "/work/b"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let ghosttySource = store.current?.cwdSource
            let ghosttyAdapter = store.current?.identity.adapterID
            let ghosttyPath = store.current?.reportedCWD

            frontmost.bundleIdentifier = "com.cmuxterm.app"
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)

            results.append(
                check(
                    "라우터: 호스트가 바뀌면 신원과 경로 출처가 함께 바뀐다",
                    ghosttySource == .ghosttyWorkingDirectory && ghosttyAdapter == "ghostty" && ghosttyPath == "/work/a"
                        && store.current?.cwdSource == .cmuxFocusedCWD
                        && store.current?.identity.adapterID == "cmux"
                        && store.current?.identity.paneID == "panel-B"
                        && store.current?.reportedCWD == "/work/b"
                        && store.previous?.reportedCWD == "/work/a",
                    "\(ghosttyAdapter ?? "-")/\(ghosttySource?.rawValue ?? "-") → \(store.current?.identity.adapterID ?? "-")/\(store.current?.cwdSource?.rawValue ?? "-")"
                )
            )
        } catch {
            results.append(check("라우터: 호스트가 바뀌면 신원과 경로 출처가 함께 바뀐다", false, "\(error)"))
        }

        return results
    }

    // MARK: - 호스트 경계 (V13)

    /// V13에서 확인하는 **호스트 사이의 경계**를 고정한다.
    ///
    /// 합성 입력으로만 만든 상태다. 실제 앱 전환 관측은 `docs/verification.md` V13에 따로 기록한다.
    private static func hostBoundaryChecks() -> [CheckResult] {
        var results: [CheckResult] = []

        /// 프로브가 `refresh()`에서 하는 것과 같은 상태로 맞춘 조회 장치.
        /// (연결을 세우지 않으면 화면 상태가 `error`가 되어 표시 규칙을 볼 수 없다.)
        func makeBoundaryStore(
            _ router: TerminalHostRouter,
            _ directories: Set<String>
        ) -> (adapter: TerminalHostRouter, store: ContextStore, resolver: FocusResolver, validator: StubValidator) {
            let made = makeHostStore(router, directories: directories)
            made.store.noteConnection(.connected)
            return made
        }

        /// 지금 표시 묶음의 화면 상태를 만든다(포커스 동결 없이).
        func displayState(_ store: ContextStore) -> DockState {
            DockStateBuilder.make(
                current: store.current,
                previous: store.previous,
                connection: store.connection,
                failure: store.lastFailure,
                lock: DockLock()
            )
        }

        // 1) 최초 실행 + 최전면 판정 불가: 기본 호스트를 **조회 후보**로 삼되 추적 중으로 표시하지 않는다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: StubFrontmostApp(nil))
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let state = displayState(store)

            results.append(
                check(
                    "V13: 최전면을 판정할 수 없으면 기본 호스트를 후보로만 삼고 추적 중으로 표시하지 않는다",
                    ghostty.queryCount == 1 && cmux.queryCount == 0
                        && store.current?.identity.adapterID == "ghostty"
                        && store.current?.focusStatus == .unknown
                        && store.current?.pathStatus == .valid
                        && state.display == .held
                        && (state.detail?.contains("포커스 확인 불가") ?? false),
                    "host=\(store.current?.identity.adapterID ?? "-") focus=\(store.current?.focusStatus.rawValue ?? "-") validity=\(store.current?.pathStatus.rawValue ?? "-") display=\(state.display.rawValue)"
                )
            )
        } catch {
            results.append(check("V13: 최전면을 판정할 수 없으면 기본 호스트를 후보로만 삼고 추적 중으로 표시하지 않는다", false, "\(error)"))
        }

        // 2) 추적 중 → 최전면 판정 불가로 바뀜: 경로는 그대로, 포커스만 내려간다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp(GhosttyAdapter.bundleIdentifier)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let wasTracked = store.current?.focusStatus == .tracked
            frontmost.bundleIdentifier = nil
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let state = displayState(store)

            results.append(
                check(
                    "V13: 최전면을 판정할 수 없게 되면 경로는 유지하고 포커스만 확인 불가로 내린다",
                    wasTracked
                        && store.current?.focusStatus == .unknown
                        && store.current?.reportedCWD == "/work/a"
                        && store.current?.pathStatus == .valid
                        && state.display == .held
                        && state.fullPath == "/work/a"
                        && (state.detail?.contains("포커스 확인 불가") ?? false),
                    "focus=\(store.current?.focusStatus.rawValue ?? "-") path=\(store.current?.reportedCWD ?? "nil") display=\(state.display.rawValue)"
                )
            )
        } catch {
            results.append(check("V13: 최전면을 판정할 수 없게 되면 경로는 유지하고 포커스만 확인 불가로 내린다", false, "\(error)"))
        }

        // 3) 호스트 전환 뒤 **이전 호스트의 응답**이 도착해도 새 대상을 덮지 않는다.
        //    두 Adapter가 **같은 형태의 pane ID**를 주는 경우까지 포함한다.
        do {
            let shared = "same-looking-pane-id"
            let ghostty = StubHostAdapter(name: "ghostty", paneID: shared, path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: shared, path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp(GhosttyAdapter.bundleIdentifier)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b"])

            let firstSnapshot = try adapter.snapshot()
            let firstRecord = adapter.focusedRecord(in: firstSnapshot)
            TerminalHostSnapshotApplier.apply(firstSnapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let generationBeforeSwitch = store.focusGeneration

            frontmost.bundleIdentifier = CmuxAdapter.bundleIdentifier
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let late = firstRecord.map { store.apply(PaneObservation(generation: generationBeforeSwitch, record: $0)) }

            results.append(
                check(
                    "V13: pane ID가 같아도 호스트가 바뀌면 세대를 올려 이전 호스트의 응답을 폐기한다",
                    late == .discardedStale
                        && store.focusGeneration > generationBeforeSwitch
                        && store.current?.identity.adapterID == "cmux"
                        && store.current?.reportedCWD == "/work/b"
                        && store.current?.cwdSource == .cmuxFocusedCWD,
                    "outcome=\(late.map(String.init(describing:)) ?? "nil") generation=\(generationBeforeSwitch)→\(store.focusGeneration) host=\(store.current?.identity.adapterID ?? "-")"
                )
            )
        } catch {
            results.append(check("V13: pane ID가 같아도 호스트가 바뀌면 세대를 올려 이전 호스트의 응답을 폐기한다", false, "\(error)"))
        }

        // 4) cmux 비터미널 panel: 안전하게 멈추고 **Ghostty로 대체하지 않는다.** 터미널로 돌아오면 복구한다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let router = makeRouter(
                ghostty: ghostty, cmux: cmux, frontmost: StubFrontmostApp(CmuxAdapter.bundleIdentifier)
            )
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b", "/work/c"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let terminalPath = store.current?.reportedCWD

            // 포커스된 panel이 브라우저가 된다.
            cmux.isTerminalPanel = false
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let stoppedPath = store.current?.reportedCWD
            let stoppedPane = store.current?.identity.paneID
            let stoppedPrevious = store.previous?.reportedCWD
            let reason = store.lastFailure ?? ""
            let substituted = ghostty.queryCount

            // 터미널 surface로 돌아온다.
            cmux.isTerminalPanel = true
            cmux.setPath("/work/c")
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)

            results.append(
                check(
                    "V13: 비터미널 panel에서는 멈추고 다른 호스트로 대체하지 않으며, 터미널 복귀 시 복구한다",
                    terminalPath == "/work/b"
                        && stoppedPath == nil
                        && stoppedPane == "-"
                        && reason.contains("not a terminal")
                        && substituted == 0
                        && stoppedPrevious == "/work/b"
                        && store.current?.reportedCWD == "/work/c"
                        && store.current?.identity.adapterID == "cmux"
                        && store.current?.focusStatus == .tracked,
                    "이전=\(terminalPath ?? "nil") 멈춤=\(stoppedPath ?? "nil") 멈춤이전=\(stoppedPrevious ?? "nil") ghostty조회=\(substituted)회 복구=\(store.current?.reportedCWD ?? "nil")"
                )
            )
        } catch {
            results.append(check("V13: 비터미널 panel에서는 멈추고 다른 호스트로 대체하지 않으며, 터미널 복귀 시 복구한다", false, "\(error)"))
        }

        // 5) 제3의 앱을 보는 동안: 마지막 작업 대상을 유지하고 pane·경로가 배경의 다른 대상으로 바뀌지 않는다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp(GhosttyAdapter.bundleIdentifier)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let paneBefore = store.current?.identity.paneID
            let pathBefore = store.current?.reportedCWD

            frontmost.bundleIdentifier = "com.example.browser"
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let state = displayState(store)

            results.append(
                check(
                    "V13: 다른 앱을 보는 동안에는 마지막 작업 대상을 유지한다",
                    paneBefore == "term-A" && pathBefore == "/work/a"
                        && store.current?.identity.paneID == "term-A"
                        && store.current?.reportedCWD == "/work/a"
                        && store.current?.focusStatus == .held
                        && state.display == .held
                        && state.canOpenFolder
                        && cmux.queryCount == 0,
                    "pane=\(store.current?.identity.paneID ?? "-") path=\(store.current?.reportedCWD ?? "nil") display=\(state.display.rawValue) cmux조회=\(cmux.queryCount)회"
                )
            )
        } catch {
            results.append(check("V13: 다른 앱을 보는 동안에는 마지막 작업 대상을 유지한다", false, "\(error)"))
        }

        // 6) 선택(실행 계획) 중 호스트가 바뀌어도 실행 대상은 선택 시점 값을 유지한다.
        do {
            let ghostty = StubHostAdapter(name: "ghostty", paneID: "term-A", path: "/work/a")
            let cmux = StubHostAdapter(name: "cmux", paneID: "panel-B", path: "/work/b", source: .cmuxFocusedCWD)
            let frontmost = StubFrontmostApp(GhosttyAdapter.bundleIdentifier)
            let router = makeRouter(ghostty: ghostty, cmux: cmux, frontmost: frontmost)
            let (adapter, store, resolver, validator) = makeBoundaryStore(router, ["/work/a", "/work/b"])

            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let frozen = store.current
            let frozenPlan = frozen.map { DockActionPlanner.plan(.copyPath, for: $0, validator: validator) }

            frontmost.bundleIdentifier = CmuxAdapter.bundleIdentifier
            TerminalHostSnapshotApplier.apply(try adapter.snapshot(), adapter: adapter, store: store, resolver: resolver, validator: validator)
            let afterHostSwitch = frozen.map { DockActionPlanner.plan(.copyPath, for: $0, validator: validator) }
            let currentPlan = store.current.map { DockActionPlanner.plan(.copyPath, for: $0, validator: validator) }

            results.append(
                check(
                    "V13: 선택 중 호스트가 바뀌어도 실행 대상은 선택 시점 값을 유지한다",
                    frozenPlan == .copyPath("/work/a")
                        && afterHostSwitch == .copyPath("/work/a")
                        && currentPlan == .copyPath("/work/b")
                        && store.current?.identity.adapterID == "cmux",
                    "frozen=\(String(describing: frozenPlan)) after=\(String(describing: afterHostSwitch)) current=\(String(describing: currentPlan))"
                )
            )
        } catch {
            results.append(check("V13: 선택 중 호스트가 바뀌어도 실행 대상은 선택 시점 값을 유지한다", false, "\(error)"))
        }

        return results
    }
}
