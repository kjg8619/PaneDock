import AppKit
import SwiftUI

/// 헤더 전용 드래그 영역.
///
/// 창 배경 드래그(`isMovableByWindowBackground`)를 **끄고** 이 영역에서만 이동하게 해서,
/// 버튼 클릭과 창 이동이 서로 잡아먹지 않게 한다.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            // 드래그가 시작되면 창을 옮긴다. 클릭만 하고 떼면 아무 일도 일어나지 않는다.
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override var mouseDownCanMoveWindow: Bool { false }
    }
}
