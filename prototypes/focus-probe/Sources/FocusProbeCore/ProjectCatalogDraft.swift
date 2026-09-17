import Foundation

/// 편집 초안. **저장/취소 전에는 실제 구성에 반영하지 않는다.**
///
/// 편집 범위는 **열 때 정하고 고정한다.** 터미널 포커스가 바뀌어도 편집 대상이 자동으로 바뀌면 안 된다 —
/// 사용자가 화면에서 보고 있는 대상을 편집해야 하기 때문이다. 범위를 바꾸려면 사용자가 직접 고른다.
///
/// 여기에는 **정적 설정만** 담긴다. pane ID·CWD·추적 잠금 같은 실시간 값은 넣지 않는다.
public struct ProjectCatalogDraft: Equatable, Sendable {
    /// 편집을 시작한 시점의 구성. **취소의 기준**이다.
    public let original: ProjectCatalog
    /// 지금까지 편집한 구성.
    public private(set) var catalog: ProjectCatalog
    /// 편집 중인 범위. 열 때 정하고, 사용자가 바꾸기 전에는 변하지 않는다.
    public private(set) var scope: ItemScope

    public init(catalog: ProjectCatalog, scope: ItemScope) {
        self.original = catalog
        self.catalog = catalog
        self.scope = scope
    }

    /// 편집한 내용이 있는지.
    public var isDirty: Bool { catalog != original }

    /// 저장하면 파일 형식이 바뀌는지(v1 → v2). 첫 저장 전에 안내하고 원본을 백업한다.
    public var requiresFormatMigration: Bool { original.schemaVersion < ProjectCatalog.currentSchemaVersion }

    // MARK: - 범위

    /// 등록된 프로젝트 요약(편집창 목록용).
    public var projects: [Project] { catalog.projects }

    public func project(id: String) -> Project? {
        catalog.projects.first { $0.id == id }
    }

    /// 범위가 지금도 유효한지(프로젝트가 사라졌으면 false).
    public func isScopeAvailable(_ scope: ItemScope) -> Bool {
        switch scope {
        case .common: return true
        case .project(let id): return project(id: id) != nil
        }
    }

    /// 범위 제목. 편집창 헤더에 그대로 보여준다.
    public func scopeTitle(_ scope: ItemScope) -> String {
        switch scope {
        case .common: return "공통 (모든 프로젝트)"
        case .project(let id): return project(id: id)?.name ?? "(없는 프로젝트)"
        }
    }

    /// 사용자가 편집 범위를 직접 바꾼다. **자동으로 바뀌는 경로는 없다.**
    public mutating func selectScope(_ scope: ItemScope) {
        guard isScopeAvailable(scope) else { return }
        self.scope = scope
    }

    /// 현재 범위의 항목(등록 순서).
    public var items: [DockItem] { items(in: scope) }

    public func items(in scope: ItemScope) -> [DockItem] {
        switch scope {
        case .common:
            return catalog.common
        case .project(let id):
            return project(id: id)?.items ?? []
        }
    }

    // MARK: - 항목 편집

    public mutating func add(_ item: DockItem, to scope: ItemScope? = nil) {
        let target = scope ?? self.scope
        switch target {
        case .common:
            catalog.common.append(item)
        case .project(let id):
            guard let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
            catalog.projects[index].items.append(item)
        }
    }

    public mutating func update(_ item: DockItem, in scope: ItemScope? = nil) {
        let target = scope ?? self.scope
        switch target {
        case .common:
            guard let index = catalog.common.firstIndex(where: { $0.id == item.id }) else { return }
            catalog.common[index] = item
        case .project(let id):
            guard let projectIndex = catalog.projects.firstIndex(where: { $0.id == id }),
                  let itemIndex = catalog.projects[projectIndex].items.firstIndex(where: { $0.id == item.id })
            else { return }
            catalog.projects[projectIndex].items[itemIndex] = item
        }
    }

    /// 항목을 목록에서 뺀다. **앱·폴더·원본 파일은 삭제하지 않는다**(바로가기만 없앤다).
    public mutating func remove(itemID: String, from scope: ItemScope? = nil) {
        let target = scope ?? self.scope
        switch target {
        case .common:
            catalog.common.removeAll { $0.id == itemID }
        case .project(let id):
            guard let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
            catalog.projects[index].items.removeAll { $0.id == itemID }
        }
    }

    /// 드래그로 순서를 바꾼다. `index`는 **옮긴 뒤의 위치**다.
    public mutating func move(itemID: String, toIndex index: Int, in scope: ItemScope? = nil) {
        let target = scope ?? self.scope
        var list = items(in: target)
        guard let current = list.firstIndex(where: { $0.id == itemID }) else { return }
        let item = list.remove(at: current)
        let clamped = max(0, min(index, list.count))
        list.insert(item, at: clamped)
        replaceItems(list, in: target)
    }

    /// 키보드용 한 칸 이동. 끝이면 아무것도 하지 않고 false를 돌려준다.
    @discardableResult
    public mutating func move(itemID: String, by offset: Int, in scope: ItemScope? = nil) -> Bool {
        let target = scope ?? self.scope
        var list = items(in: target)
        guard let current = list.firstIndex(where: { $0.id == itemID }) else { return false }
        let destination = current + offset
        guard destination >= 0, destination < list.count else { return false }
        let item = list.remove(at: current)
        list.insert(item, at: destination)
        replaceItems(list, in: target)
        return true
    }

    private mutating func replaceItems(_ list: [DockItem], in scope: ItemScope) {
        switch scope {
        case .common:
            catalog.common = list
        case .project(let id):
            guard let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
            catalog.projects[index].items = list
        }
    }

    // MARK: - 프로젝트

    /// 새 프로젝트를 등록한다(이름 + 기준 폴더). 만들어진 id를 돌려준다.
    public mutating func addProject(name: String, root: String) -> String {
        let id = Self.makeProjectID(existing: Set(catalog.projects.map(\.id)), name: name)
        catalog.projects.append(Project(id: id, name: name, root: root))
        return id
    }

    public mutating func updateProject(id: String, name: String, root: String) {
        guard let index = catalog.projects.firstIndex(where: { $0.id == id }) else { return }
        catalog.projects[index].name = name
        catalog.projects[index].root = root
    }

    // MARK: - 검증

    public func fatalProblems() -> [String] {
        ProjectCatalogValidator.fatalProblems(in: catalog)
    }

    public func diagnostics() -> [String] {
        ProjectCatalogValidator.diagnostics(for: catalog)
    }

    /// 새 항목·프로젝트에 쓸 고유 id.
    public static func makeItemID(existing: Set<String>) -> String {
        var candidate = UUID().uuidString
        while existing.contains(candidate) {
            candidate = UUID().uuidString
        }
        return candidate
    }

    static func makeProjectID(existing: Set<String>, name: String) -> String {
        let base = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var candidate = base.isEmpty ? "project" : base
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}
