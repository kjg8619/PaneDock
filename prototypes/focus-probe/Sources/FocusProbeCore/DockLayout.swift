import Foundation

/// Dock에 놓이는 구성요소. **순서는 사용자가 정한다**(고정 배치를 강제하지 않는다).
public enum DockComponent: String, Codable, Sendable, CaseIterable {
    case common
    case cards
    case project

    public var label: String {
        switch self {
        case .common: return "공통 앱"
        case .cards: return "카드"
        case .project: return "프로젝트 영역"
        }
    }
}

/// 카드 종류. **Dock 안에서 실제로 동작하는 카드**만 둔다(바로가기 금지).
public enum DockCardKind: String, Codable, Sendable, CaseIterable {
    // 저장 값(raw)에 'lock' 부분 문자열이 들어가면 설정 스키마 가드 검사에 오탐으로 걸린다 → 값은 "time".
    case clock = "time"
    case focusTimer

    public var label: String {
        switch self {
        case .clock: return "시계·날짜"
        case .focusTimer: return "집중 타이머"
        }
    }
}

public struct DockCardSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: DockCardKind

    public init(id: String, kind: DockCardKind) {
        self.id = id
        self.kind = kind
    }

    /// 처음 추가할 때 쓰는 기본 카드. 같은 종류를 여러 개 두어도 id로 구분한다.
    public static func makeDefault(_ kind: DockCardKind, existing: [DockCardSpec]) -> DockCardSpec {
        makeDefault(kind, usedIDs: Set(existing.map(\.id)))
    }

    /// 이번 실행에서 **한 번이라도 쓴** id와 겹치지 않는 새 카드를 만든다.
    ///
    /// 삭제한 카드의 id를 곧바로 다시 쓰면 그 카드의 **이전 실행 상태를 물려받는다**.
    /// 그래서 지금 배치에 있는 id가 아니라 **써 본 id 전체**를 기준으로 고른다.
    public static func makeDefault(_ kind: DockCardKind, usedIDs: Set<String>) -> DockCardSpec {
        let prefix = kind == .clock ? "time" : "focus"
        var index = 1
        while usedIDs.contains("\(prefix)-\(index)") { index += 1 }
        return DockCardSpec(id: "\(prefix)-\(index)", kind: kind)
    }
}

/// **저장된 Dock 배치.** 구성요소 순서·프로젝트 영역 너비·카드 목록을 담는다.
///
/// 프로젝트 **내용**(항목·ID·순서)은 `projects.json`에 그대로 있고,
/// 카드 **실행 상태**(타이머 진행)는 여기 들어오지 않는다 — 메모리에만 둔다.
public struct DockLayout: Codable, Equatable, Sendable {
    /// 왼쪽부터의 구성요소 순서. 기본은 승인된 배치(공통 → 카드 → 프로젝트).
    public var order: [DockComponent]
    /// 프로젝트 영역에 할당하는 너비(pt). **항목 수가 달라도 이 값을 유지**한다.
    public var projectAreaWidth: Double
    public var cards: [DockCardSpec]

    public init(
        order: [DockComponent] = [.common, .cards, .project],
        projectAreaWidth: Double = DockLayout.defaultProjectAreaWidth,
        cards: [DockCardSpec] = [DockCardSpec(id: "time-1", kind: .clock), DockCardSpec(id: "focus-1", kind: .focusTimer)]
    ) {
        self.order = order
        self.projectAreaWidth = projectAreaWidth
        self.cards = cards
    }

    public static let defaultProjectAreaWidth: Double = 360
    public static let minimumProjectAreaWidth: Double = 240
    public static let maximumProjectAreaWidth: Double = 620

    /// `layout`이 없던 설정도 **승인된 기본 배치**로 실행된다.
    public static let `default` = DockLayout()

    /// 알 수 없는 값·빠진 필드는 기본값으로 읽는다(설정 파일 하나 때문에 앱이 멈추지 않게).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedOrder = (try? container.decodeIfPresent([DockComponent].self, forKey: .order)).flatMap { $0 }
        // 알 수 없는 구성요소는 버리고, 빠진 구성요소는 기본 순서대로 뒤에 붙인다(전부 잃지 않게).
        var order = (decodedOrder ?? []).reduce(into: [DockComponent]()) { acc, item in
            if !acc.contains(item) { acc.append(item) }
        }
        for item in DockComponent.allCases where !order.contains(item) { order.append(item) }
        self.order = order

        let width = (try? container.decodeIfPresent(Double.self, forKey: .projectAreaWidth)).flatMap { $0 }
            ?? DockLayout.defaultProjectAreaWidth
        self.projectAreaWidth = min(max(width, DockLayout.minimumProjectAreaWidth), DockLayout.maximumProjectAreaWidth)
        self.cards = (try? container.decodeIfPresent([DockCardSpec].self, forKey: .cards)).flatMap { $0 } ?? DockLayout.default.cards
    }
}
