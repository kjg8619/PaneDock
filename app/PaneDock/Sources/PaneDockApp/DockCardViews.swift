import AppKit
import FocusProbeCore
import SwiftUI

/// 카드 공통 배경(승인된 위젯 규격: 높이 68 · 둥근 모서리 17 · 유리 패널).
private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

/// 시계·날짜 카드. **실제 현재 시각**을 보여준다(바로가기가 아니다).
struct ClockCardView: View {
    let now: Date

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 EEEE"
        return formatter
    }()

    private static let fullFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 EEEE HH:mm:ss"
        return formatter
    }()

    private var fullText: String { Self.fullFormat.string(from: now) }

    var body: some View {
        HStack(spacing: 10) {
            ClockFace(now: now)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.timeFormat.string(from: now))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(Self.dateFormat.string(from: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 13)
        .frame(width: DockBarLayout.clockCardWidth, height: DockBarLayout.cardHeight)
        .background(CardBackground())
        .help("현재 시각 — \(fullText)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("시계: \(fullText)")
    }
}

/// 초 진행 링 + 시·분침이 있는 미니 아날로그 시계.
private struct ClockFace: View {
    let now: Date

    var body: some View {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let seconds = Double(parts.second ?? 0)
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60

        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 3)
            // 초 진행 링(현재 초 비율).
            Circle()
                .trim(from: 0, to: seconds / 60)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1.5)
            hand(length: 9, width: 2.5, angle: hours * 30, opacity: 1)
            hand(length: 12, width: 2, angle: minutes * 6, opacity: 0.6)
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    /// 바늘 하나. **면 중심**을 축으로 돌린다(오프셋을 준 도형을 ZStack으로 감싸 회전).
    private func hand(length: CGFloat, width: CGFloat, angle: Double, opacity: Double) -> some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(opacity))
                .frame(width: width, height: length)
                .offset(y: -length / 2)
        }
        .rotationEffect(.degrees(angle))
    }
}

/// 집중 타이머 카드. **Dock 안에서 실제로 동작한다**(시작·일시정지·재설정).
///
/// 남은 시간은 `FocusTimerState`가 시작 시각으로 계산한다(표시 갱신 횟수에 의존하지 않는다).
/// `00:00`에서는 상태 문구·버튼 표시가 **끝난 상태**로 맞춰진다(▶ = 처음부터 다시 시작).
struct FocusTimerCardView: View {
    let cardID: String
    let state: FocusTimerState
    let now: Date
    let focusedControl: DockFocusControl?
    let hoveredControl: DockFocusControl?
    let onAction: (DockTimerAction) -> Void
    let onHover: (DockFocusControl?) -> Void

    private var isRunning: Bool { state.isRunning(at: now) }
    private var isFinished: Bool { state.isFinished(at: now) }
    private var statusText: String { state.statusText(at: now) }

    var body: some View {
        HStack(spacing: 10) {
            ring
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFinished ? Color.orange : Color.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    control(
                        .start,
                        symbol: isFinished ? "arrow.clockwise" : "play.fill",
                        help: isFinished
                            ? "끝났습니다 — 처음부터 다시 시작 (25분)"
                            : "타이머 시작 (남은 \(state.text(at: now)))",
                        isOn: isRunning
                    )
                    control(
                        .pause,
                        symbol: "pause.fill",
                        help: "일시정지 (남은 \(state.text(at: now)))",
                        isOn: !isRunning && !isFinished && state.elapsed(at: now) > 0
                    )
                    control(
                        .reset,
                        symbol: "arrow.counterclockwise",
                        help: "재설정 — 25분으로 되돌립니다",
                        isOn: false
                    )
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(width: DockBarLayout.timerCardWidth, height: DockBarLayout.cardHeight)
        .background(CardBackground())
        .help("집중 타이머 — \(statusText), 남은 시간 \(state.text(at: now))")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("집중 타이머 \(statusText), 남은 시간 \(state.text(at: now))")
    }

    /// 남은 비율 링 + 가운데 남은 시간.
    private var ring: some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: state.remainingFraction(at: now))
                .stroke(
                    isFinished ? Color.orange : (isRunning ? Color.green : Color.primary.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(2)
            Text(state.text(at: now))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }

    /// 카드 조작 버튼. 상태는 **모양(채움)·아이콘·문구**로 구분하고 색만으로 전달하지 않는다.
    private func control(_ action: DockTimerAction, symbol: String, help: String, isOn: Bool) -> some View {
        let focus = DockFocusControl.timer(cardID: cardID, action: action)
        return Button(action: { onAction(action) }) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(isOn ? Color.green.opacity(0.22) : Color.primary.opacity(0.08))
                )
                .overlay(
                    Circle().strokeBorder(isOn ? Color.green.opacity(0.5) : Color.primary.opacity(0.15), lineWidth: 1)
                )
                .overlay(
                    Circle().strokeBorder(
                        hoveredControl == focus ? Color.primary.opacity(0.35) : Color.clear,
                        lineWidth: 2
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        focusedControl == focus ? Color.accentColor : Color.clear,
                        lineWidth: 2.5
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { onHover($0 ? focus : nil) }
        .help(help)
        .accessibilityLabel(help)
    }
}
