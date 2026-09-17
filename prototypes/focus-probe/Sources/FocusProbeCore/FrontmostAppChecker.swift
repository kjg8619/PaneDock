import AppKit
import Foundation

/// OS가 판단한 최전면 앱.
///
/// cmux 소켓은 "앱이 최전면인지"를 알려주지 않는다(테스트용 `set`만 있다).
/// 그래서 **OS에서** 읽는다 — 화면을 읽지 않고, 앱을 활성화하지도 않는다.
/// `NSWorkspace.frontmostApplication`은 macOS가 제공하는 표준 API다.
///
/// **nil을 false로 바꾸지 않는다.** 이 프로세스가 WindowServer에 연결되지 않은 문맥
/// (TTY 없이 분리 실행 등)에서는 값이 nil이 되는데, 그것을 "최전면 아님"으로 처리하면
/// 창이 "유지 중"으로 잘못 표시된다(V11 실측).
public struct WorkspaceFrontmostAppChecker: FrontmostAppChecking {
    public init() {}

    public func isFrontmost(_ bundleIdentifier: String) -> Bool? {
        NSWorkspace.shared.frontmostApplication.map { $0.bundleIdentifier == bundleIdentifier }
    }
}
