import Foundation

/// Dock 바 크기. **현재 외형(76pt)을 기본값**으로 두고 세 단계로 나눈다.
public enum DockSizeSetting: String, Codable, Sendable, CaseIterable {
    case small
    case regular
    case large

    public var label: String {
        switch self {
        case .small: return "작게"
        case .regular: return "기본"
        case .large: return "크게"
        }
    }

    /// 바 높이(pt). **승인된 위젯 규격(104pt)이 기본값**이고, 작게·크게는 그 기준에서 움직인다.
    /// 창 생성·리사이즈·상세 보기 계산이 모두 이 값을 쓴다.
    public var barHeight: CGFloat {
        switch self {
        case .small: return 92
        case .regular: return DockBarLayout.widgetBarHeight
        case .large: return 116
        }
    }
}

/// 항목 표시 방식. **라벨을 줄이는 기능**이며, 이름을 숨긴 항목에는 툴팁·접근성 이름을 준다.
public enum DockLabelMode: String, Codable, Sendable, CaseIterable {
    case nameAndIcon
    case iconOnly

    public var label: String {
        switch self {
        case .nameAndIcon: return "아이콘+이름"
        case .iconOnly: return "아이콘 중심"
        }
    }

    /// 등록 항목의 라벨을 그릴지.
    public var showsItemLabels: Bool { self == .nameAndIcon }
}

/// 색상 모드. `system`이면 지금까지처럼 시스템을 따른다.
public enum DockColorMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "시스템"
        case .light: return "밝게"
        case .dark: return "어둡게"
        }
    }
}

/// Dock 외형 설정. **항목 구성과는 별개**이며 `settings.json`에 저장한다.
///
/// 값이 없던 이전 설정 파일에서도 **기본 외형(현재 모습)** 으로 동작해야 한다 —
/// 그래서 모든 필드의 기본값이 지금까지의 모습과 같다.
public struct DockAppearance: Codable, Equatable, Sendable {
    public var size: DockSizeSetting
    public var labelMode: DockLabelMode
    public var colorMode: DockColorMode
    /// 표시 모드. **이전 설정 파일에는 없으므로** 없으면 `alwaysVisible`(지금까지의 동작)로 읽는다.
    public var displayMode: DockDisplayMode

    public init(
        size: DockSizeSetting = .regular,
        labelMode: DockLabelMode = .nameAndIcon,
        colorMode: DockColorMode = .system,
        displayMode: DockDisplayMode = .alwaysVisible
    ) {
        self.size = size
        self.labelMode = labelMode
        self.colorMode = colorMode
        self.displayMode = displayMode
    }

    /// 지금까지의 외형. 기본값으로 쓴다.
    public static let `default` = DockAppearance()

    /// 알 수 없는 값이 들어 있어도 기본값으로 떨어진다(손상된 파일 때문에 앱이 멈추지 않게).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? container.decodeIfPresent(DockSizeSetting.self, forKey: .size)) .flatMap { $0 } ?? .regular
        labelMode = (try? container.decodeIfPresent(DockLabelMode.self, forKey: .labelMode)).flatMap { $0 } ?? .nameAndIcon
        colorMode = (try? container.decodeIfPresent(DockColorMode.self, forKey: .colorMode)).flatMap { $0 } ?? .system
        displayMode = (try? container.decodeIfPresent(DockDisplayMode.self, forKey: .displayMode)).flatMap { $0 } ?? .alwaysVisible
    }
}
