import CryptoKit
import Foundation

// 프로젝트 카탈로그 — 공통 항목과 프로젝트별 항목.
//
// 이 파일이 다루는 것은 **사용자가 명시적으로 등록한 정적 설정**이다.
// 실시간 pane ID·CWD·잠금 상태와는 성격이 다르며, 영구 저장하더라도 그 값들을 저장하지 않는다.
//
// **읽기는 자동으로 하고, 쓰기는 사용자가 편집창에서 "저장"을 눌렀을 때만 한다.**
// 손상·미래 버전 파일은 해석하지 않고, 그 위에 덮어쓰지도 않는다.

/// v1 형식의 링크. **읽기 호환용으로만 남긴다**(새로 쓰지 않는다 → `DockItem`이 대신한다).
public struct ProjectLink: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// `http` 또는 `https`만 허용한다. 다른 스킴은 진단에 남기고 목록에서 제외한다.
    public var url: String

    public init(id: String, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

public struct Project: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// 기준 폴더(절대 경로). 사용자가 명시한 값이며 실시간 CWD와 구분해 표시한다.
    public var root: String
    /// 이 프로젝트에서 추가로 표시하는 항목(등록 순서).
    public var items: [DockItem]

    public init(id: String, name: String, root: String, items: [DockItem] = []) {
        self.id = id
        self.name = name
        self.root = root
        self.items = items
    }
}

public struct ProjectCatalog: Codable, Equatable, Sendable {
    /// v2에서 `common`(공통 항목)과 `items`(프로젝트 항목)가 들어왔다. v1의 `links`도 계속 읽는다.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// 프로젝트와 관계없이 항상 표시하는 항목.
    public var common: [DockItem]
    public var projects: [Project]

    public init(
        schemaVersion: Int = ProjectCatalog.currentSchemaVersion,
        common: [DockItem] = [],
        projects: [Project] = []
    ) {
        self.schemaVersion = schemaVersion
        self.common = common
        self.projects = projects
    }
}

/// v1·v2 파일을 모두 읽고, 항상 v2로 쓴다.
///
/// v1의 `projects[].links`는 **링크 항목으로 옮겨 읽는다**(id·이름·URL·순서 보존).
/// 저장할 때는 v2 형식으로만 쓰므로, v1 파일을 처음 저장할 때 형식이 바뀐다 —
/// 그때 원본을 백업하고 사용자에게 알린다(호출자 책임).
public extension ProjectCatalog {
    /// 파일에서 읽는다. v1·v2 모두 허용한다.
    static func decode(from data: Data) throws -> ProjectCatalog {
        let raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        let projects = (raw.projects ?? []).map { project in
            var items = project.items ?? []
            // v1의 링크를 항목으로 옮긴다. 뒤에 붙여 **원래 순서를 보존**한다.
            items.append(
                contentsOf: (project.links ?? []).map {
                    DockItem(id: $0.id, kind: .link, name: $0.name, target: $0.url)
                }
            )
            return Project(id: project.id, name: project.name, root: project.root, items: items)
        }
        return ProjectCatalog(
            schemaVersion: raw.schemaVersion ?? 1,
            common: raw.common ?? [],
            projects: projects
        )
    }

    /// 저장용 데이터. 항상 현재 스키마 버전으로 쓴다.
    func encoded() throws -> Data {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        return try JSONEncoder().encode(copy)
    }

    /// 읽기 전용 원본. 모르는 키가 있어도 무시하고, v1의 `links`를 받아들인다.
    private struct RawCatalog: Decodable {
        var schemaVersion: Int?
        var common: [DockItem]?
        var projects: [RawProject]?
    }

    private struct RawProject: Decodable {
        var id: String
        var name: String
        var root: String
        var items: [DockItem]?
        /// v1 형식. 새로 쓰지 않는다.
        var links: [ProjectLink]?
    }
}
public enum ProjectCatalogLoadOutcome: Equatable, Sendable {
    /// 파일이 없다. 등록된 프로젝트가 없는 상태로 동작한다.
    case fresh
    case loaded
    /// 읽을 수 없거나 형식·스키마가 맞지 않는다. **원본 파일은 건드리지 않는다.**
    case corrupt
    /// 이 앱이 모르는(더 새로운) 스키마 버전이다. **파일을 건드리지 않는다.**
    case unsupportedVersion(found: Int)

    public var label: String {
        switch self {
        case .fresh: return "fresh"
        case .loaded: return "loaded"
        case .corrupt: return "corrupt"
        case .unsupportedVersion(let found): return "unsupportedVersion(\(found))"
        }
    }

    /// 이 결과를 새 구성으로 적용할 수 있는지. 손상·미래 버전은 적용하지 않는다.
    public var isUsable: Bool {
        self == .fresh || self == .loaded
    }
}

/// 저장 결과. **초안은 호출자가 들고 있고, 실패하면 파일은 그대로다.**
public enum ProjectCatalogSaveOutcome: Equatable, Sendable {
    /// 저장했다. 형식 전환 등으로 원본을 백업했으면 그 경로를 함께 돌려준다.
    case saved(backupPath: String?)
    /// 이 파일에는 쓸 수 없다(메모리 전용·손상·미래 버전·검증 실패).
    case refused(reason: String)
    /// 편집 중 외부에서 파일이 바뀌었다. **덮어쓰지 않았다.**
    case conflict(detail: String)
    case failed(reason: String)

    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    /// 저장하지 못한 사유. 성공이면 nil. 화면에 그대로 보여줄 수 있다.
    public var rejectionReason: String? {
        switch self {
        case .saved: return nil
        case .refused(let reason): return reason
        case .conflict(let detail): return detail
        case .failed(let reason): return reason
        }
    }

    /// 다시 시도하기 전에 사용자가 **다시 읽어야 하는지**(외부 변경 충돌).
    public var requiresReload: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// 저장 규칙은 설정과 같다(손상·미래 버전은 해석하지 않음).
///
/// **읽기는 자동, 쓰기는 사용자가 저장을 눌렀을 때만.** 자동 복구·자동 덮어쓰기는 하지 않는다.
public final class ProjectCatalogStore {
    public private(set) var outcome: ProjectCatalogLoadOutcome = .fresh
    public private(set) var catalog = ProjectCatalog()
    /// 설정 자체의 문제(중복 ID·중복 기준 폴더·잘못된 URL 등). 사용자에게 안내하기 위한 것이다.
    public private(set) var diagnostics: [String] = []

    private let url: URL?
    /// 마지막으로 읽은 파일 내용의 지문. 저장 직전에 외부 변경을 판단하는 데만 쓴다.
    private var loadedSignature: String?

    public init(url: URL?) {
        self.url = url
        load()
    }

    public var fileURL: URL? { url }
    public var isMemoryOnly: Bool { url == nil }
    public var isUsable: Bool { outcome.isUsable }

    /// 파일을 다시 읽는다. 같은 인스턴스로 여러 번 호출할 수 있다.
    @discardableResult
    public func reload() -> ProjectCatalogLoadOutcome {
        load()
        return outcome
    }

    public func load() {
        diagnostics = []
        guard let url else {
            outcome = .fresh
            catalog = ProjectCatalog()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            outcome = .fresh
            catalog = ProjectCatalog()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            outcome = .corrupt
            catalog = ProjectCatalog()
            return
        }
        guard let decoded = try? ProjectCatalog.decode(from: data) else {
            // 형식이 깨졌다. 원본은 그대로 둔다.
            outcome = .corrupt
            catalog = ProjectCatalog()
            loadedSignature = nil
            return
        }
        guard decoded.schemaVersion <= ProjectCatalog.currentSchemaVersion else {
            // 미래 버전은 해석하지 않는다. 파일도 건드리지 않는다.
            outcome = .unsupportedVersion(found: decoded.schemaVersion)
            catalog = ProjectCatalog()
            loadedSignature = nil
            return
        }
        outcome = .loaded
        catalog = decoded
        loadedSignature = Self.signature(of: data)
        diagnostics = ProjectCatalogValidator.diagnostics(for: decoded)
    }

    /// 파일 내용의 지문. 저장 직전에 **외부에서 바뀌었는지** 판단하는 데만 쓴다.
    static func signature(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 편집한 구성을 저장한다. **사용자가 저장을 눌렀을 때만 호출한다.**
    ///
    /// - 검증에 실패하면 아무것도 쓰지 않는다(초안은 호출자가 그대로 들고 있다).
    /// - 기존 파일이 있으면 **먼저 백업**하고, 임시 파일에 쓴 뒤 **원자적으로 교체**한다.
    /// - 저장 직전에 지문을 다시 확인해 **외부 변경을 덮어쓰지 않는다.**
    /// - 손상·미래 버전 파일 위에는 쓰지 않는다.
    /// - 성공하면 디스크에서 다시 읽어 메모리 상태와 지문을 맞춘다.
    @discardableResult
    public func save(_ draft: ProjectCatalog) -> ProjectCatalogSaveOutcome {
        guard let url else {
            return .refused(reason: "메모리 전용 설정에는 저장할 수 없습니다")
        }
        guard outcome.isUsable else {
            return .refused(reason: "읽지 못한 파일 위에 저장하지 않습니다 (\(outcome.label))")
        }
        let problems = ProjectCatalogValidator.fatalProblems(in: draft)
        guard problems.isEmpty else {
            return .refused(reason: problems.joined(separator: "\n"))
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            guard let current = try? Data(contentsOf: url) else {
                return .failed(reason: "현재 파일을 읽을 수 없어 저장하지 않았습니다")
            }
            if let loadedSignature, Self.signature(of: current) != loadedSignature {
                return .conflict(detail: "편집 중에 프로젝트 파일이 밖에서 바뀌었습니다. 덮어쓰지 않았습니다.")
            }
        }

        var backupPath: String?
        if exists {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)")
            do {
                try FileManager.default.copyItem(at: url, to: backup)
                backupPath = backup.path
            } catch {
                return .failed(reason: "원본 백업에 실패해 저장하지 않았습니다: \(error.localizedDescription)")
            }
        }

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        do {
            let data = try draft.encoded()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            if exists {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failed(reason: "저장에 실패했습니다: \(error.localizedDescription)")
        }

        load()
        return .saved(backupPath: backupPath)
    }
}

/// 카탈로그 적용 결과. 앱은 이 값만 화면·모델에 반영한다.
public struct ProjectCatalogApplication: Equatable, Sendable {
    public var catalog: ProjectCatalog
    public var diagnostics: [String]
    /// 사용자에게 보여줄 안내. 없으면 nil.
    public var note: String?
    /// 새 구성을 적용했는지(실패하면 false → 이전 구성 유지).
    public var appliedNewConfiguration: Bool
}

public enum ProjectCatalogApplier {
    /// 로딩 결과를 **하나의 일관된 구성**으로 확정한다.
    ///
    /// - `fresh`/`loaded`: 새 구성을 적용한다(파일이 없으면 빈 카탈로그 = 기본 Dock).
    /// - `corrupt`/`unsupportedVersion`: **이전 정상 구성을 유지**하고 그 사실을 알린다.
    /// - 어느 경우에도 사용자 파일을 고치지 않는다(호출자가 파일을 건드리지 않는다).
    public static func apply(
        load outcome: ProjectCatalogLoadOutcome,
        loadedCatalog: ProjectCatalog,
        loadedDiagnostics: [String],
        previousCatalog: ProjectCatalog,
        previousDiagnostics: [String],
        isReload: Bool
    ) -> ProjectCatalogApplication {
        guard outcome.isUsable else {
            return ProjectCatalogApplication(
                catalog: previousCatalog,
                diagnostics: previousDiagnostics,
                note: "설정 읽기 실패 — 이전 설정 사용 중 (\(outcome.label))\n프로젝트 파일은 그대로 두었습니다. 내용을 고친 뒤 메뉴에서 다시 읽어 주세요.",
                appliedNewConfiguration: false
            )
        }

        var parts: [String] = []
        if isReload {
            parts.append(
                loadedCatalog.projects.isEmpty
                    ? "프로젝트 설정을 다시 읽었습니다 — 등록된 프로젝트가 없어 기본 Dock으로 동작합니다"
                    : "프로젝트 설정을 다시 읽었습니다 — 프로젝트 \(loadedCatalog.projects.count)개"
            )
        }
        // 로더의 경고(중복 기준 폴더·잘못된 URL 등)는 조용히 무시하지 않는다.
        parts.append(contentsOf: loadedDiagnostics.prefix(3))

        return ProjectCatalogApplication(
            catalog: loadedCatalog,
            diagnostics: loadedDiagnostics,
            note: parts.isEmpty ? nil : parts.joined(separator: "\n"),
            appliedNewConfiguration: true
        )
    }
}

// MARK: - 경로 비교

public enum ProjectPath {
    /// 심볼릭 링크 정책: **비교할 때는 링크를 해석한다.**
    ///
    /// macOS에서 `/tmp`는 `/private/tmp`로 이어지는 등 같은 폴더가 여러 경로로 표현될 수 있다.
    /// 사용자가 `/tmp/proj`로 등록하고 셸이 `/private/tmp/proj`를 보고해도 같은 프로젝트로 보는 편이
    /// 기대에 맞다. **표시에는 항상 원본 문자열을 그대로 쓴다**(등록값과 보고값 모두).
    public static func comparisonPath(_ path: String) -> String {
        let standardized = PathNormalizer.normalize(path)
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return PathNormalizer.normalize(resolved)
    }

    /// 폴더 경계를 지키며 부분 경로인지 판정한다.
    /// `/work/shop-old`는 `/work/shop`의 하위가 아니다.
    public static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        let candidate = components(comparisonPath(path))
        let base = components(comparisonPath(root))
        guard !base.isEmpty, candidate.count >= base.count else { return false }
        return Array(candidate.prefix(base.count)) == base
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

// MARK: - 검증

public enum ProjectCatalogValidator {
    public static func diagnostics(for catalog: ProjectCatalog) -> [String] {
        var messages: [String] = []

        var seenProjectIDs = Set<String>()
        var rootsSeen: [String: [String]] = [:]

        for item in catalog.common {
            if let problem = DockItemValidator.problem(with: item) {
                messages.append("공통 항목: \(problem) (\(item.name))")
            }
        }
        var seenCommonIDs = Set<String>()
        for item in catalog.common where !seenCommonIDs.insert(item.id).inserted {
            messages.append("공통 항목 id가 중복됩니다: \(item.id)")
        }

        for project in catalog.projects {
            if project.id.isEmpty {
                messages.append("프로젝트에 id가 없습니다: \(project.name.isEmpty ? "(이름 없음)" : project.name)")
            } else if !seenProjectIDs.insert(project.id).inserted {
                messages.append("프로젝트 id가 중복됩니다: \(project.id)")
            }
            if !project.root.hasPrefix("/") {
                messages.append("기준 폴더가 절대 경로가 아닙니다: \(project.root) (\(project.name))")
            }
            rootsSeen[ProjectPath.comparisonPath(project.root), default: []].append(project.id)

            var seenItemIDs = Set<String>()
            for item in project.items {
                if let problem = DockItemValidator.problem(with: item) {
                    messages.append("\(project.name): \(problem)")
                }
                if !seenItemIDs.insert(item.id).inserted {
                    messages.append("항목 id가 중복됩니다: \(item.id) (\(project.name))")
                }
            }
        }

        for (root, ids) in rootsSeen where ids.count > 1 {
            messages.append("기준 폴더가 중복 등록되었습니다: \(root) → \(ids.joined(separator: ", "))")
        }

        return messages.sorted()
    }

    /// **저장을 막아야 하는** 문제만 고른다.
    ///
    /// 중복 ID와 형식 오류는 파일을 모호하거나 쓸 수 없게 만든다. 반면 기준 폴더가 절대 경로가 아닌 것
    /// 같은 문제는 경고로 두고 저장은 허용한다(사용자가 나중에 고칠 수 있다).
    ///
    /// **항목 id는 범위 안에서만 고유하면 된다.** 프로젝트가 다르면 같은 id를 써도 된다 —
    /// v1의 `links`도 프로젝트별로만 고유했고, 표시·실행은 (범위, id)로 찾는다.
    /// 여기서 전체 고유를 요구하면 **기존에 잘 쓰던 파일이 저장 거부된다**(V15에서 실제로 발생).
    public static func fatalProblems(in catalog: ProjectCatalog) -> [String] {
        var problems: [String] = []

        var seenCommonIDs = Set<String>()
        for item in catalog.common {
            if item.id.isEmpty { problems.append("공통 항목에 id가 없습니다") }
            else if !seenCommonIDs.insert(item.id).inserted {
                problems.append("공통 항목 id가 중복됩니다: \(item.id)")
            }
            if let problem = DockItemValidator.problem(with: item) {
                problems.append("공통 항목: \(problem)")
            }
        }

        var seenProjectIDs = Set<String>()
        for project in catalog.projects {
            if project.id.isEmpty { problems.append("프로젝트에 id가 없습니다") }
            else if !seenProjectIDs.insert(project.id).inserted {
                problems.append("프로젝트 id가 중복됩니다: \(project.id)")
            }
            var seenItemIDs = Set<String>()
            for item in project.items {
                if item.id.isEmpty { problems.append("항목에 id가 없습니다 (\(project.name))") }
                else if !seenItemIDs.insert(item.id).inserted {
                    problems.append("항목 id가 중복됩니다: \(item.id) (\(project.name))")
                }
                if let problem = DockItemValidator.problem(with: item) {
                    problems.append("\(project.name): \(problem)")
                }
            }
        }

        return problems
    }

    public static func isAllowedScheme(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: - 매칭

public enum ProjectMatchResult: Equatable, Sendable {
    /// 등록된 프로젝트가 없다 → 기본 Dock으로 동작한다.
    case none
    case matched(Project)
    /// 같은 기준 폴더가 여러 번 등록되어 모호하다. 아무것도 고르지 않고 안내한다.
    case ambiguous(root: String, projectIDs: [String])
}

public enum ProjectMatcher {
    /// 가장 구체적인(가장 깊은) 기준 폴더를 고른다. 폴더 경계를 지킨다.
    public static func match(cwd: String, in catalog: ProjectCatalog) -> ProjectMatchResult {
        let candidates = catalog.projects.filter { ProjectPath.isSameOrDescendant(cwd, of: $0.root) }
        guard !candidates.isEmpty else { return .none }

        let depth = { (project: Project) in ProjectPath.components(ProjectPath.comparisonPath(project.root)).count }
        guard let deepest = candidates.map(depth).max() else { return .none }
        let mostSpecific = candidates.filter { depth($0) == deepest }

        if mostSpecific.count > 1 {
            let root = ProjectPath.comparisonPath(mostSpecific[0].root)
            return .ambiguous(root: root, projectIDs: mostSpecific.map(\.id).sorted())
        }
        return .matched(mostSpecific[0])
    }
}

// MARK: - 표시·실행 묶음

/// 한 시점의 표시 묶음. **공통 항목과 프로젝트 항목을 함께** 들고 있다.
///
/// 프로젝트가 없어도 만들어진다(`hasProject == false`). 공통 항목은 그때도 표시된다.
public struct ProjectResolution: Equatable, Sendable {
    public var projectID: String
    public var projectName: String
    /// 사용자가 등록한 기준 폴더(원본 문자열).
    public var projectRoot: String
    /// 이 판정을 만든 CWD(원본 문자열). 기준 폴더와 구분해 표시한다.
    public var matchedCWD: String
    /// 프로젝트와 관계없이 항상 표시하는 항목(등록 순서).
    public var commonItems: [DockItemTarget]
    /// 현재 프로젝트의 항목(등록 순서).
    public var projectItems: [DockItemTarget]
    public var diagnostics: [String]

    public init(
        projectID: String,
        projectName: String,
        projectRoot: String,
        matchedCWD: String,
        commonItems: [DockItemTarget],
        projectItems: [DockItemTarget],
        diagnostics: [String]
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.matchedCWD = matchedCWD
        self.commonItems = commonItems
        self.projectItems = projectItems
        self.diagnostics = diagnostics
    }

    /// 등록된 프로젝트가 현재 경로에 맞았는지.
    public var hasProject: Bool { !projectID.isEmpty }

    /// 화면·키보드가 쓰는 순서: **공통 → 프로젝트 항목**.
    public var allItems: [DockItemTarget] { commonItems + projectItems }
}

public enum ProjectResolver {
    /// CWD와 카탈로그로 표시 묶음을 만든다. **프로젝트가 없어도 공통 항목은 담는다.**
    ///
    /// 형식이 잘못된 항목(빈 이름·잘못된 URL 등)은 목록에서 제외한다 — 진단에 남는다.
    public static func resolve(
        cwd: String,
        catalog: ProjectCatalog,
        catalogDiagnostics: [String] = []
    ) -> ProjectResolution {
        let common = targets(for: catalog.common, scope: .common)
        guard case .matched(let project) = ProjectMatcher.match(cwd: cwd, in: catalog) else {
            return ProjectResolution(
                projectID: "",
                projectName: "",
                projectRoot: "",
                matchedCWD: cwd,
                commonItems: common,
                projectItems: [],
                diagnostics: catalogDiagnostics
            )
        }
        return ProjectResolution(
            projectID: project.id,
            projectName: project.name,
            projectRoot: project.root,
            matchedCWD: cwd,
            commonItems: common,
            projectItems: targets(for: project.items, scope: .project(id: project.id)),
            diagnostics: catalogDiagnostics
        )
    }

    /// 항목을 표시·실행용 묶음으로 옮긴다. 형식이 잘못된 항목은 제외한다.
    public static func targets(for items: [DockItem], scope: ItemScope) -> [DockItemTarget] {
        items
            .filter(DockItemValidator.isWellFormed)
            .map {
                DockItemTarget(
                    scopeID: scope.scopeID,
                    isCommon: scope == .common,
                    itemID: $0.id,
                    kind: $0.kind,
                    name: $0.name,
                    target: $0.target
                )
            }
    }

    /// 모호한 경우를 포함해 상태를 돌려준다(UI 안내용).
    public static func status(cwd: String, catalog: ProjectCatalog, catalogDiagnostics: [String]) -> ProjectMatchResult {
        _ = catalogDiagnostics
        return ProjectMatcher.match(cwd: cwd, in: catalog)
    }
}

/// 로그·진단에 남길 수 있는 URL 형태로 줄인다.
///
/// 실제 링크에 토큰이나 서명된 쿼리가 붙어 있을 수 있으므로 **쿼리·프래그먼트·사용자정보를 제거**한다.
/// 화면 표시는 사용자가 등록한 원본을 그대로 쓴다(자기 화면에서 자기 링크를 보는 것은 의도된 동작).
public enum ProjectLinkPrivacy {
    public static func redactedForLog(_ url: String) -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, let host = parsed.host else {
            return "<invalid-url>"
        }
        let path = parsed.path
        return "\(scheme)://\(host)\(path.isEmpty ? "" : path)"
    }
}

public enum ProjectSelection {
    /// 설정을 다시 읽은 뒤에도 **진행 중인 항목 선택을 유지해도 되는지** 판정한다.
    ///
    /// 프로젝트가 바뀌었거나 표시 목록(개수·순서·ID·대상)이 달라졌으면 false다.
    /// 이때는 이전 인덱스를 새 목록에 그대로 적용하지 않고 **선택을 취소한다**.
    public static func selectionSurvives(reloadFrom old: ProjectResolution?, to new: ProjectResolution?) -> Bool {
        guard let old, let new else { return false }
        guard old.projectID == new.projectID else { return false }
        let previous = old.allItems
        let next = new.allItems
        guard previous.count == next.count else { return false }
        return zip(previous, next).allSatisfy { before, after in
            before.itemID == after.itemID && before.target == after.target && before.kind == after.kind
        }
    }
}

// MARK: - 실행

public enum DockItemActionPlan: Equatable, Sendable {
    case openApplication(URL)
    case openFolder(URL)
    case openURL(URL)
    case reject(reason: String)

    public var rejectionReason: String? {
        if case .reject(let reason) = self { return reason }
        return nil
    }
}

public enum DockItemActionPlanner {
    /// 항목 실행 계획. 마우스와 키보드가 **같은 경로**로 들어온다.
    ///
    /// - **공통 항목**은 터미널 추적 상태와 **독립적으로** 실행할 수 있다. 대상 자체가 유효하면 된다.
    ///   그래도 **표시 중인 목록에 있는 항목이어야** 한다 — 이전 순번으로 다른 항목을 실행하지 않는다.
    /// - **프로젝트 항목**은 기존 규칙을 그대로 따른다(오류·확인 중에는 막고, 프로젝트가 바뀌면 거부).
    /// - 파일 대상(앱·폴더)은 **존재까지** 확인한다. 없으면 실행하지 않는다.
    public static func plan(
        target: DockItemTarget,
        in resolution: ProjectResolution?,
        state: DockState,
        validator: PathValidating
    ) -> DockItemActionPlan {
        guard let resolution else {
            return .reject(reason: "표시 중인 항목이 없습니다")
        }
        let stillShown = resolution.allItems.contains {
            $0.itemID == target.itemID && $0.scopeID == target.scopeID && $0.target == target.target
        }
        guard stillShown else {
            return .reject(reason: "선택한 항목을 현재 표시에서 찾을 수 없습니다. 다시 선택해 주세요")
        }

        if !target.isCommon {
            guard state.isActionable else {
                return .reject(reason: "지금은 실행할 수 없습니다: \(state.detail ?? "실행할 대상을 확인하는 중입니다")")
            }
            guard resolution.projectID == target.scopeID else {
                return .reject(reason: "프로젝트가 바뀌었습니다. 다시 선택해 주세요")
            }
        }
        return planForTarget(target, validator: validator)
    }

    /// 대상 종류별 검증·계획.
    static func planForTarget(_ target: DockItemTarget, validator: PathValidating) -> DockItemActionPlan {
        switch target.kind {
        case .app:
            guard target.target.hasPrefix("/"), validator.isDirectory(target.target) else {
                return .reject(reason: "앱을 찾을 수 없습니다: \(target.target)")
            }
            return .openApplication(URL(fileURLWithPath: target.target))
        case .folder:
            guard target.target.hasPrefix("/"), validator.isDirectory(target.target) else {
                return .reject(reason: "폴더를 찾을 수 없습니다: \(target.target)")
            }
            return .openFolder(URL(fileURLWithPath: target.target))
        case .link:
            guard ProjectCatalogValidator.isAllowedScheme(target.target), let url = URL(string: target.target) else {
                return .reject(reason: "허용되지 않는 링크입니다(http/https만): \(target.target)")
            }
            return .openURL(url)
        }
    }
}
