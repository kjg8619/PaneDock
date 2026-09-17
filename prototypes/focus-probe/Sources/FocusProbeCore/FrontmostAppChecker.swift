import AppKit
import Foundation

/// OS가 판단한 최전면 앱.
///
/// cmux 소켓은 "앱이 최전면인지"를 알려주지 않는다(테스트용 `set`만 있다).
/// 그래서 **OS에서** 읽는다 — 화면을 읽지 않고, 앱을 활성화하지도 않는다.
/// `NSWorkspace.frontmostApplication`은 macOS가 제공하는 표준 API다.
public struct WorkspaceFrontmostAppChecker: FrontmostAppChecking {
    public init() {}

    public func isFrontmost(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }
}
