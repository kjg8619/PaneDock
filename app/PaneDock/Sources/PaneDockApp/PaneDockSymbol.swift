import AppKit

/// A 시안의 **pane 형태 심볼**을 코드로 그린다.
///
/// 시안 이미지를 에셋으로 붙이지 않고, 같은 형태(둥근 사각형 + 세로 분할 + 점 + 아래 막대 3개)를
/// 도형으로 그린다. 앱 아이콘(컬러)과 메뉴바 심볼(단색 템플릿)이 같은 형태를 쓴다.
enum PaneDockSymbol {
    /// 메뉴바용 **단색 템플릿** 이미지. 시스템이 밝기·강조 색에 맞춰 그린다.
    static func menuBarImage(size: CGFloat = 18, isActive: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let stroke = isActive ? NSColor.black : NSColor.black.withAlphaComponent(0.45)
            draw(in: rect, stroke: stroke, fill: nil, lineWidth: max(1.2, size * 0.075))
            return true
        }
        // 단색 템플릿: 시스템이 메뉴 막대 색에 맞춘다.
        image.isTemplate = true
        return image
    }

    /// 앱 아이콘용 컬러 렌더(A 시안의 파란 그라디언트 타일).
    static func appIconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.2
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                                          xRadius: radius, yRadius: radius)
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.42, green: 0.62, blue: 1.00, alpha: 1),
                NSColor(calibratedRed: 0.16, green: 0.30, blue: 0.78, alpha: 1),
            ])
            gradient?.draw(in: background, angle: -70)
            draw(in: rect.insetBy(dx: size * 0.2, dy: size * 0.2),
                 stroke: NSColor.white.withAlphaComponent(0.95),
                 fill: NSColor.white.withAlphaComponent(0.16),
                 lineWidth: max(1, size * 0.035))
            return true
        }
    }

    /// 시안의 pane 형태: 왼쪽 작은 사각형 + 오른쪽 큰 사각형(점 하나) + 아래 막대 3개.
    private static func draw(in rect: NSRect, stroke: NSColor, fill: NSColor?, lineWidth: CGFloat) {
        stroke.setStroke()
        fill?.setFill()

        let w = rect.width
        let h = rect.height
        let outer = NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: w, height: h),
            xRadius: w * 0.16,
            yRadius: h * 0.16
        )
        outer.lineWidth = lineWidth
        outer.stroke()
        fill?.setFill()
        outer.fill()

        let pad = w * 0.16
        let gap = w * 0.08
        let bottom = h * 0.30
        let leftWidth = (w - pad * 2 - gap) * 0.42
        let rightWidth = (w - pad * 2 - gap) - leftWidth

        // 가로 분할선(위쪽 pane 영역과 아래 막대 영역).
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: rect.minX + pad * 0.7, y: rect.minY + bottom))
        divider.line(to: NSPoint(x: rect.maxX - pad * 0.7, y: rect.minY + bottom))
        divider.lineWidth = lineWidth
        divider.stroke()

        // 왼쪽 작은 pane.
        let left = NSBezierPath(
            roundedRect: NSRect(x: rect.minX + pad, y: rect.minY + bottom + gap,
                                width: leftWidth, height: h - bottom - gap - pad),
            xRadius: w * 0.06, yRadius: w * 0.06
        )
        left.lineWidth = lineWidth
        left.fill()
        left.stroke()

        // 오른쪽 큰 pane + 점.
        let right = NSBezierPath(
            roundedRect: NSRect(x: rect.minX + pad + leftWidth + gap, y: rect.minY + bottom + gap,
                                width: rightWidth, height: h - bottom - gap - pad),
            xRadius: w * 0.06, yRadius: w * 0.06
        )
        right.lineWidth = lineWidth
        right.fill()
        right.stroke()

        let dotSize = max(lineWidth * 1.6, w * 0.09)
        stroke.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: rect.maxX - pad - dotSize * 1.2, y: rect.maxY - pad - dotSize * 1.2,
                           width: dotSize, height: dotSize)
        ).fill()

        // 아래 막대 3개.
        let barHeight = bottom * 0.5
        let barY = rect.minY + bottom * 0.28
        let barWidth = (w - pad * 2 - gap * 2) / 3
        for index in 0..<3 {
            let bar = NSBezierPath(
                roundedRect: NSRect(x: rect.minX + pad + CGFloat(index) * (barWidth + gap),
                                    y: barY, width: barWidth, height: barHeight),
                xRadius: barHeight / 2, yRadius: barHeight / 2
            )
            bar.lineWidth = lineWidth
            bar.fill()
            bar.stroke()
        }
    }
}
