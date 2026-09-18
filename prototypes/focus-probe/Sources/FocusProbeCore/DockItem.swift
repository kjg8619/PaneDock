import Foundation

/// Dock에 놓는 항목의 종류.
public enum DockItemKind: String, Codable, Sendable, CaseIterable {
    case app
    case folder
    case link

    public var label: String {
        switch self {
        case .app: return "앱"
        case .folder: return "폴더"
        case .link: return "링크"
        }
    }
}

/// 사용자가 등록한 Dock 항목. **정적 설정**이다.
///
/// pane ID·CWD·잠금 상태·추적 결과 같은 **실시간 값은 담지 않는다**(영구 저장 금지).
/// 순서가 바뀌어도 유지되는 고유 `id`를 쓴다.
public struct DockItem: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DockItemKind
    public var name: String
    /// `app`: `.app` 번들 경로 · `folder`: 절대 경로 · `link`: http·https URL
    public var target: String

    public init(id: String = UUID().uuidString, kind: DockItemKind, name: String, target: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
    }
}

/// 항목이 어느 범위에 속하는지. 편집창 제목과 선택 검증에 쓴다.
public enum ItemScope: Equatable, Sendable {
    /// 프로젝트와 관계없이 항상 표시하는 항목.
    case common
    /// 등록된 프로젝트 하나의 항목.
    case project(id: String)

    public var scopeID: String {
        switch self {
        case .common: return "common"
        case .project(let id): return id
        }
    }
}

/// 표시·실행에 쓰는 항목 하나. **어느 범위의 무엇인지**를 함께 들고 다닌다.
///
/// 클릭·키보드 실행은 이 값을 그대로 검증에 넘긴다. 순서가 바뀌어도 id로 찾으므로
/// 이전 순번으로 다른 항목이 실행되지 않는다.
public struct DockItemTarget: Equatable, Sendable {
    public var scopeID: String
    public var isCommon: Bool
    public var itemID: String
    public var kind: DockItemKind
    public var name: String
    public var target: String

    public init(scopeID: String, isCommon: Bool, itemID: String, kind: DockItemKind, name: String, target: String) {
        self.scopeID = scopeID
        self.isCommon = isCommon
        self.itemID = itemID
        self.kind = kind
        self.name = name
        self.target = target
    }

    /// 파일 시스템에 있어야 하는 대상인지(앱·폴더).
    public var isFileSystemTarget: Bool {
        kind == .app || kind == .folder
    }
}

/// 표시·선택에서 항목을 가리키는 **신원**. 순번(index)이 아니라 **범위 + ID**로 가리킨다.
///
/// 순번은 목록이 다시 만들어지면 다른 항목을 가리킬 수 있다. 범위와 ID를 함께 쓰면
/// 프로젝트가 바뀌거나 순서가 달라져도 같은 항목만 실행된다.
public struct DockItemRef: Equatable, Hashable, Sendable {
    public var scopeID: String
    public var itemID: String

    public init(scopeID: String, itemID: String) {
        self.scopeID = scopeID
        self.itemID = itemID
    }

    /// 로그·검사에서 읽을 수 있는 형태.
    public var label: String { "\(scopeID)/\(itemID)" }
}

extension DockItemTarget {
    public var ref: DockItemRef { DockItemRef(scopeID: scopeID, itemID: itemID) }
}

/// 항목의 대상이 **형식상** 올바른지 검사한다. 존재 여부는 실행 시점에 본다
/// (외장 볼륨처럼 잠시 없을 수 있는 대상을 저장 단계에서 막지 않는다).
public enum DockItemValidator {
    public static func isWellFormed(_ item: DockItem) -> Bool {
        problem(with: item) == nil
    }

    /// 형식 문제가 있으면 사유, 없으면 nil.
    public static func problem(with item: DockItem) -> String? {
        if item.id.isEmpty { return "항목 id가 없습니다" }
        if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "이름이 비어 있습니다"
        }
        let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return "대상이 비어 있습니다" }
        switch item.kind {
        case .app:
            guard target.hasPrefix("/"), target.hasSuffix(".app") else {
                return "앱은 .app 번들의 절대 경로여야 합니다: \(target)"
            }
        case .folder:
            guard target.hasPrefix("/") else {
                return "폴더는 절대 경로여야 합니다: \(target)"
            }
        case .link:
            guard ProjectCatalogValidator.isAllowedScheme(target) else {
                return "허용되지 않는 링크입니다(http/https만): \(target)"
            }
        }
        return nil
    }
}
