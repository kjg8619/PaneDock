import FocusProbeCore
import SwiftUI

/// 단일 화면. 작은 떠 있는 창 하나만 그린다.
///
/// 상태는 색만으로 전달하지 않는다. 항상 한국어 상태 이름을 함께 보여준다.
struct DockView: View {
    @ObservedObject var model: DockModel

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isFake {
                Text("FAKE DATA — 실제 Ghostty에 연결되지 않았습니다")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 6) {
                Text(stateLabel)
                    .font(.caption).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stateColor.opacity(0.18))
                    .foregroundStyle(stateColor)
                    .clipShape(Capsule())
                    .accessibilityLabel("상태: \(stateLabel)")
                Spacer()
                if let observed = model.state.observedAt {
                    Text(Self.timeFormatter.string(from: observed))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 헤더만 드래그 영역이다. 버튼과 겹치지 않아 클릭과 이동이 충돌하지 않는다.
            .background(WindowDragHandle())

            Text(model.state.folderName)
                .font(.title2).bold()
                .lineLimit(1)
                .truncationMode(.middle)

            Text(model.state.fullPath ?? "확인 중")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let detail = model.state.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let previous = model.state.previousPath {
                Text("이전 위치: \(previous)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()

            HStack(spacing: 6) {
                actionButton("폴더 열기", control: .openFolder, enabled: model.state.canOpenFolder) {
                    model.perform(.openFolder, source: .mouse)
                }
                actionButton("경로 복사", control: .copyPath, enabled: model.state.canCopyPath) {
                    model.perform(.copyPath, source: .mouse)
                }
                actionButton(model.state.isLocked ? "잠금 해제" : "잠금", control: .lock, enabled: true) {
                    model.toggleLock()
                }
            }

            if let message = model.actionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = model.settingsNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(metaText)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                actionButton("숨기기", control: .hide, enabled: true) { model.hideWindow() }
                actionButton("종료", control: .quit, enabled: true) { NSApplication.shared.terminate(nil) }
            }

            Text("Tab 이동 · Enter 실행 · Esc 닫기 · ⌃⌥⌘D 호출")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .frame(width: 360)
    }

    /// 마우스와 키보드가 같은 동작으로 들어간다. 키보드 포커스는 테두리로 표시한다.
    private func actionButton(
        _ title: String,
        control: DockModel.Control,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            model.focusedControl == control ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }

    private var stateLabel: String {
        switch model.state.display {
        case .tracked: return "추적 중"
        case .held: return "유지 중"
        case .locked: return "잠금"
        case .pending: return "확인 중"
        case .error: return "오류"
        }
    }

    private var stateColor: Color {
        switch model.state.display {
        case .tracked: return .green
        case .held: return .orange
        case .locked: return .blue
        case .pending: return .gray
        case .error: return .red
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let pane = model.state.paneID { parts.append(String(pane.prefix(8))) }
        if let frontmost = model.state.hostFrontmost {
            parts.append(frontmost ? "Ghostty 최전면" : "Ghostty 비활성")
        }
        return parts.isEmpty ? "대상 없음" : parts.joined(separator: " · ")
    }
}
