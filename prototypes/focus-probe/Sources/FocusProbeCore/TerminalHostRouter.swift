import Foundation

/// 여러 터미널 호스트(Ghostty, cmux) 중 **지금 따라갈 하나**를 고른다.
///
/// ## 선택 규칙 (V12)
///
/// 1. 최전면 앱이 목록의 호스트면 **그 호스트**.
/// 2. 아니면 **마지막으로 고른 호스트** — 둘 다 뒤에 있으면 그 대상이 "유지 중"으로 남는다.
/// 3. 아직 고른 적이 없으면 목록의 **첫 번째**(기본 호스트).
///
/// 최전면을 **판정할 수 없으면**(`frontmostBundleIdentifier()`가 nil) 규칙 2·3으로 내려간다.
/// "최전면 아님"으로 단정하지 않는다 — 그러면 창이 거짓으로 "유지 중"이 된다(V11.11).
///
/// ## 조회 비용과 실패 처리
///
/// 조회는 **고른 호스트 하나만** 한다. 추적하지 않는 호스트가 꺼져 있거나 오류여도
/// 현재 추적에 영향을 주지 않는다. 반대로 **고른 호스트의 조회가 실패하면 그 실패를 그대로 보고**한다.
/// 조용히 다른 호스트로 갈아타지 않는다(연결 실패와 정상 추적을 섞지 않는다).
///
/// ## 동시성
///
/// `GhosttyProbe`와 같은 직렬 문맥에서만 쓴다. 그래서 `@unchecked Sendable`이다.
public final class TerminalHostRouter: TerminalHostAdapter, @unchecked Sendable {
    /// 추적 후보. 최전면 판정에 쓸 번들 식별자를 함께 둔다.
    public struct Host: Sendable {
        public var adapter: TerminalHostAdapter
        public var bundleIdentifier: String

        public init(adapter: TerminalHostAdapter, bundleIdentifier: String) {
            self.adapter = adapter
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// 후보 목록. **순서가 기본 우선순위**다(0번이 기본 호스트).
    public private(set) var hosts: [Host]
    private let frontmost: FrontmostAppChecking
    private var lastIndex: Int?

    public init(hosts: [Host], frontmost: FrontmostAppChecking = WorkspaceFrontmostAppChecker()) {
        precondition(!hosts.isEmpty, "호스트가 하나 이상 필요하다")
        self.hosts = hosts
        self.frontmost = frontmost
    }

    /// 지금 따라갈 호스트 인덱스. 규칙 1 → 2 → 3.
    public func currentIndex() -> Int {
        if let frontmostID = frontmost.frontmostBundleIdentifier(),
           let index = hosts.firstIndex(where: { $0.bundleIdentifier == frontmostID }) {
            return index
        }
        if let lastIndex { return lastIndex }
        return 0
    }

    /// 마지막으로 고른 호스트의 이름. 진단·표시에 쓴다.
    public var currentHostName: String { chosen.adapter.appName }

    // MARK: - TerminalHostAdapter

    public func snapshot() throws -> TerminalHostSnapshot {
        let index = currentIndex()
        // 고른 호스트를 기억한다. 다음 조회에서 최전면이 아니어도 이 대상을 유지한다.
        lastIndex = index
        var snapshot = try hosts[index].adapter.snapshot()
        // **응답에 호스트를 붙인다.** 이후 위임은 이 값으로 호스트를 정하므로,
        // 응답을 받은 뒤 선택이 바뀌어도 그 응답은 원래 호스트로 변환된다.
        snapshot.sourceIndex = index
        // 최전면 판정은 **라우터가 한 번만** 한다. 호스트 Adapter가 따로 판정하면
        // "확인된 포커스"와 "확인 불가"가 서로 어긋난다.
        snapshot.frontmost = frontmost.isFrontmost(hosts[index].bundleIdentifier)
        return snapshot
    }

    /// `snapshot()`이 고른 호스트. 그 이후의 위임은 모두 이 호스트로 간다.
    ///
    /// 스냅샷과 레코드 변환이 **같은 호스트**에서 나와야 한다. 두 호스트의 식별자 체계가 다르므로
    /// 섞이면 다른 pane의 경로를 현재 대상으로 표시하게 된다.
    private var chosen: Host { hosts[lastIndex ?? 0] }

    /// 이 스냅샷을 만든 호스트. **스냅샷에 붙은 값을 먼저 본다** —
    /// 응답을 받은 뒤 라우터 선택이 바뀌어도 그 응답은 원래 호스트로 변환해야 한다.
    private func host(for snapshot: TerminalHostSnapshot) -> Host {
        hosts[min(max(snapshot.sourceIndex ?? lastIndex ?? 0, 0), hosts.count - 1)]
    }

    public var appName: String { chosen.adapter.appName }

    public var appleScriptRequirement: String? { chosen.adapter.appleScriptRequirement }

    public var factory: WorkInfoFactory { chosen.adapter.factory }

    public func unsupportedVersionReason(_ version: String?) -> String? {
        chosen.adapter.unsupportedVersionReason(version)
    }

    public func focusedRecord(in snapshot: TerminalHostSnapshot) -> PaneRecord? {
        host(for: snapshot).adapter.focusedRecord(in: snapshot)
    }

    public func records(in snapshot: TerminalHostSnapshot) -> [PaneRecord] {
        host(for: snapshot).adapter.records(in: snapshot)
    }

    public func noTargetReason(in snapshot: TerminalHostSnapshot) -> String {
        host(for: snapshot).adapter.noTargetReason(in: snapshot)
    }
}
