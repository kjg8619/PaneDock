import AppKit
import FocusProbeCore
import Foundation

/// 화면 배치를 코어의 순수 계산에 넘겨주는 얇은 계층.
///
/// 다중 화면 동시 표시나 전체화면 대응은 하지 않는다. 저장된 좌표가 지금 보이는지만 판정한다.
enum ScreenGeometry {
    /// Dock과 메뉴 막대를 제외한 영역들.
    static var visibleFrames: [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    /// 보정 기준이 되는 화면(주 화면).
    static var fallbackFrame: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 저장된 좌표(없으면 기본 위치)를 지금 화면에 보이는 위치로 확정한다.
    static func resolve(origin: CGPoint?, size: CGSize) -> CGPoint {
        guard let origin else {
            return WindowPlacement.defaultOrigin(in: fallbackFrame)
        }
        return WindowPlacement.clamp(
            origin: origin,
            size: size,
            screens: visibleFrames,
            fallback: fallbackFrame
        )
    }

    /// 가로형 Dock 창의 크기. 화면 너비와 항목 수로 정해진다.
    ///
    /// 기본 위치는 **화면 하단**이다(`WindowPlacement.defaultOrigin`). macOS Dock과 메뉴 막대는
    /// `visibleFrame`에서 이미 제외되므로 그 위에 놓인다.
    static func dockBarSize(linkCount: Int, detailsVisible: Bool) -> CGSize {
        let available = fallbackFrame.width
        let visibleLinks = DockBarLayout.linkBudget(total: linkCount, availableWidth: available).visible
        return CGSize(
            width: DockBarLayout.barWidth(visibleLinkCount: visibleLinks, availableWidth: available),
            height: DockBarLayout.windowHeight(detailsVisible: detailsVisible)
        )
    }
}
