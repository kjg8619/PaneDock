import AppKit
import FocusProbeCore
import Foundation

/// 화면 배치를 코어의 순수 계산에 넘겨주는 얇은 계층.
///
/// 다중 화면 동시 표시나 전체화면 대응은 하지 않는다. 저장된 좌표가 지금 보이는지만 판정한다.
/// **창 크기는 표시 목록(`DockModel.display`)이 정한다** — 여기서 다시 계산하지 않는다.
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

    /// 패널이 놓인 화면(없으면 주 화면).
    static func targetScreen(for panelFrame: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(panelFrame) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Custom의 기준 위치: **대상 화면의 실제 아래 가장자리**.
    ///
    /// `visibleFrame`은 기본 Dock·메뉴 막대 영역을 **제외한** 값이라, 기본 Dock을 숨기고 쓰는
    /// Custom에서는 화면 아래에 빈 띠가 남는다. Custom의 기준은 화면 프레임의 아래 끝이다.
    static func bottomAnchorOrigin(for size: CGSize, panelFrame: CGRect) -> CGPoint {
        let screen = targetScreen(for: panelFrame)
        let frame = screen?.frame ?? fallbackFrame
        return CGPoint(x: max(frame.minX + 12, frame.midX - size.width / 2), y: frame.minY)
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
}
