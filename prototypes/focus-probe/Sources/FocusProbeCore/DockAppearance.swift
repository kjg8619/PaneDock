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

    /// 바 높이(pt). 컴포넌트 기준으로 세 단계가 실제로 구분되는 값.
    public var barHeight: CGFloat {
        switch self {
        case .small: return 64
        case .regular: return 76
        case .large: return 92
        }
    }

    /// 칩(항목·동작 버튼)의 세로 여백. 높이에 맞춰 클릭 영역을 확보한다.
    public var chipVerticalPadding: CGFloat {
        switch self {
        case .small: return 5
        case .regular: return 7
        case .large: return 9
        }
    }

    /// 항목 영역이 확보해야 하는 최소 너비. 작은 모드에서 이름이 사라지지 않게 한다.
    public var minimumItemAreaWidth: CGFloat {
        switch self {
        case .small: return 170
        case .regular: return 190
        case .large: return 210
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

    public init(
        size: DockSizeSetting = .regular,
        labelMode: DockLabelMode = .nameAndIcon,
        colorMode: DockColorMode = .system
    ) {
        self.size = size
        self.labelMode = labelMode
        self.colorMode = colorMode
    }

    /// 지금까지의 외형. 기본값으로 쓴다.
    public static let `default` = DockAppearance()

    /// 알 수 없는 값이 들어 있어도 기본값으로 떨어진다(손상된 파일 때문에 앱이 멈추지 않게).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? container.decodeIfPresent(DockSizeSetting.self, forKey: .size)) .flatMap { $0 } ?? .regular
        labelMode = (try? container.decodeIfPresent(DockLabelMode.self, forKey: .labelMode)).flatMap { $0 } ?? .nameAndIcon
        colorMode = (try? container.decodeIfPresent(DockColorMode.self, forKey: .colorMode)).flatMap { $0 } ?? .system
    }
}
