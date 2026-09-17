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
        _ = store.apply(PaneObservation(generation: 1, record: record(pane: "w1:p1", cwd: "/work/a")))
        let trackedBefore = store.current?.focusStatus == .tracked

        store.alignTarget(to: record(pane: "w1:p2", cwd: "/work/b"))
        let currentPending = store.current?.pathStatus == .pending && store.current?.focusStatus == .pending
        let currentHasNoPath = store.current?.reportedCWD == nil
        let previousKeptSeparate = store.previous?.reportedCWD == "/work/a" && store.previous?.identity.paneID == "w1:p1"
        let pendingDetail = "current.path=\(store.current?.reportedCWD ?? "nil") previous.path=\(store.previous?.reportedCWD ?? "nil")"

        _ = store.apply(
            PaneObservation(generation: store.focusGeneration, record: record(pane: "w1:p2", cwd: "/work/b"))
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
            guard !outputs.isEmpty else { throw GhosttyQueryError.other("stub exhausted") }
            return outputs.removeFirst()
        }
    }

    /// AppleScript 스크립트가 실제로 내는 것과 같은 형식의 출력을 만든다.
    private static func ghosttyOutput(
        version: String = "1.3.1",
        frontmost: Bool = true,
        frontWindow: String = "win-1",
        selectedTab: String = "tab-1",
        focused: String = "term-A",
        terminals: [(window: String, tab: String, id: String, wd: String?, name: String?)]
    ) -> String {
        var lines: [String] = [
            "version=\(version)",
            "frontmost=\(frontmost)",
            "frontWindow=\(frontWindow)",
            "selectedTab=\(selectedTab)",
            "focusedTerminal=\(focused)",
            "focusedWD=\(terminals.first { $0.id == focused }?.wd ?? "")",
        ]
        for terminal in terminals {
            lines.append("term=\(terminal.window)\t\(terminal.tab)\t\(terminal.id)\t\(terminal.wd ?? "")\t\(terminal.name ?? "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func makeGhosttyStore(
        directories: Set<String>,
        outputs: [String]
    ) -> (adapter: GhosttyAdapter, store: ContextStore, resolver: FocusResolver, validator: StubValidator) {
        let adapter = GhosttyAdapter(runner: StubAppleScript(outputs: outputs))
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
                    ghosttyOutput(focused: "term-A", terminals: twoPanes),
                    ghosttyOutput(focused: "term-B", terminals: twoPanes),
                ]
            )
            let first = try adapter.snapshot()
            GhosttySnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let firstPane = store.current?.identity.paneID
            let firstPath = store.current?.reportedCWD

            let second = try adapter.snapshot()
            GhosttySnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)
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
                    ghosttyOutput(focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?)]),
                    ghosttyOutput(focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/c", name: "a" as String?)]),
                ]
            )
            let first = try adapter.snapshot()
            GhosttySnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let generationBefore = store.focusGeneration
            let second = try adapter.snapshot()
            GhosttySnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)

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
                    ghosttyOutput(focused: "term-A", terminals: twoPanes),
                    ghosttyOutput(
                        focused: "term-A",
                        terminals: [
                            (window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?),
                            (window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/c", name: "b" as String?),
                        ]
                    ),
                ]
            )
            let first = try adapter.snapshot()
            GhosttySnapshotApplier.apply(first, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let second = try adapter.snapshot()
            let result = GhosttySnapshotApplier.apply(second, adapter: adapter, store: store, resolver: resolver, validator: validator)

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
                    ghosttyOutput(
                        focused: "term-A",
                        terminals: [
                            (window: "win-1", tab: "tab-1", id: "term-A", wd: nil, name: "no-path" as String?),
                            (window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/gone", name: "gone" as String?),
                        ]
                    )
                ]
            )
            let snapshot = try adapter.snapshot()
            GhosttySnapshotApplier.apply(snapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
            let noPath = store.current?.pathStatus == .unsupported && store.current?.focusStatus == .unknown

            let (adapter2, store2, resolver2, validator2) = makeGhosttyStore(
                directories: [],
                outputs: [ghosttyOutput(focused: "term-B", terminals: [(window: "win-1", tab: "tab-1", id: "term-B", wd: "/work/gone", name: "gone" as String?)])]
            )
            let snapshot2 = try adapter2.snapshot()
            GhosttySnapshotApplier.apply(snapshot2, adapter: adapter2, store: store2, resolver: resolver2, validator: validator2)
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
                outputs: [ghosttyOutput(frontmost: false, focused: "term-A", terminals: [(window: "win-1", tab: "tab-1", id: "term-A", wd: "/work/a", name: "a" as String?)])]
            )
            let snapshot = try adapter.snapshot()
            GhosttySnapshotApplier.apply(snapshot, adapter: adapter, store: store, resolver: resolver, validator: validator)
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
        let cases: [(String, Int, GhosttyQueryError, ConnectionStatus)] = [
            ("앱 미실행", -600, .notRunning, .unavailable),
            ("자동화 권한 거부", -1743, .automationDenied, .denied),
            ("AppleScript 미지원", -1708, .appleScriptUnsupported, .incompatible),
            ("창 없음", -1728, .noWindow, .connected),
        ]
        return cases.map { label, code, expected, status in
            let classified = GhosttyQueryError.classify(
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
            let snapshot = try GhosttyAdapter.parse(
                ghosttyOutput(focused: "term-B", terminals: [
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
            _ = try GhosttyAdapter.parse("notRunning=true\n")
            results.append(check("파싱: 미실행 응답 거부", false, "오류가 나지 않았다"))
        } catch let failure as GhosttyQueryError {
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
}
