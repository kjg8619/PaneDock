import Foundation

// 프로젝트별 웹 링크 (0.1c 최소 구현).
//
// 이 파일이 다루는 것은 **사용자가 명시적으로 등록한 정적 설정**이다.
// 실시간 pane ID·CWD·잠금 상태와는 성격이 다르며, 영구 저장하더라도 그 값들을 저장하지 않는다.
//
// 이번 구현은 카탈로그를 **읽기만** 한다. 사용자 파일을 앱이 덮어쓰지 않는다.

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
    public var links: [ProjectLink]

    public init(id: String, name: String, root: String, links: [ProjectLink]) {
        self.id = id
        self.name = name
        self.root = root
        self.links = links
    }
}

public struct ProjectCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var projects: [Project]

    public init(schemaVersion: Int = ProjectCatalog.currentSchemaVersion, projects: [Project] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
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

/// 저장 규칙은 설정과 같다(손상·미래 버전은 해석하지 않음).
///
/// **사용자 파일을 절대 고치지 않는다.** 손상돼도 백업으로 옮기거나 지우지 않고 그대로 두고,
/// 읽기 실패만 보고한다. 앱이 설정을 자동 복구하는 일은 없다.
public final class ProjectCatalogStore {
    public private(set) var outcome: ProjectCatalogLoadOutcome = .fresh
    public private(set) var catalog = ProjectCatalog()
    /// 설정 자체의 문제(중복 ID·중복 기준 폴더·잘못된 URL 등). 사용자에게 안내하기 위한 것이다.
    public private(set) var diagnostics: [String] = []

    private let url: URL?

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
        guard let decoded = try? JSONDecoder().decode(ProjectCatalog.self, from: data) else {
            // 형식이 깨졌다. 원본은 그대로 둔다.
            outcome = .corrupt
            catalog = ProjectCatalog()
            return
        }
        guard decoded.schemaVersion <= ProjectCatalog.currentSchemaVersion else {
            // 미래 버전은 해석하지 않는다. 파일도 건드리지 않는다.
            outcome = .unsupportedVersion(found: decoded.schemaVersion)
            catalog = ProjectCatalog()
            return
        }
        outcome = .loaded
        catalog = decoded
        diagnostics = ProjectCatalogValidator.diagnostics(for: decoded)
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

            var seenLinkIDs = Set<String>()
            for link in project.links {
                if !seenLinkIDs.insert(link.id).inserted {
                    messages.append("링크 id가 중복됩니다: \(link.id) (\(project.name))")
                }
                if !isAllowedScheme(link.url) {
                    messages.append("허용되지 않는 링크입니다(http/https만): \(link.url) (\(project.name))")
                }
            }
        }

        for (root, ids) in rootsSeen where ids.count > 1 {
            messages.append("기준 폴더가 중복 등록되었습니다: \(root) → \(ids.joined(separator: ", "))")
        }

        return messages.sorted()
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

/// 표시에 쓰는 링크 하나. 프로젝트 ID·항목 ID·URL을 한 묶음으로 들고 다닌다.
public struct ProjectLinkTarget: Equatable, Sendable {
    public var projectID: String
    public var linkID: String
    public var name: String
    public var url: String

    public init(projectID: String, linkID: String, name: String, url: String) {
        self.projectID = projectID
        self.linkID = linkID
        self.name = name
        self.url = url
    }
}

/// 한 시점의 프로젝트 판정 결과. 링크 목록과 그 근거가 된 CWD를 함께 묶는다.
public struct ProjectResolution: Equatable, Sendable {
    public var projectID: String
    public var projectName: String
    /// 사용자가 등록한 기준 폴더(원본 문자열).
    public var projectRoot: String
    /// 이 판정을 만든 CWD(원본 문자열). 기준 폴더와 구분해 표시한다.
    public var matchedCWD: String
    /// 유효한 링크만, 등록 순서 그대로.
    public var links: [ProjectLinkTarget]
    public var diagnostics: [String]

    public init(
        projectID: String,
        projectName: String,
        projectRoot: String,
        matchedCWD: String,
        links: [ProjectLinkTarget],
        diagnostics: [String]
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.projectRoot = projectRoot
        self.matchedCWD = matchedCWD
        self.links = links
        self.diagnostics = diagnostics
    }
}

public enum ProjectResolver {
    /// CWD와 카탈로그로 표시 묶음을 만든다. 유효한 링크만 담는다.
    public static func resolve(cwd: String, catalog: ProjectCatalog, catalogDiagnostics: [String] = []) -> ProjectResolution? {
        guard case .matched(let project) = ProjectMatcher.match(cwd: cwd, in: catalog) else { return nil }
        let links = project.links
            .filter { ProjectCatalogValidator.isAllowedScheme($0.url) }
            .map { ProjectLinkTarget(projectID: project.id, linkID: $0.id, name: $0.name, url: $0.url) }
        return ProjectResolution(
            projectID: project.id,
            projectName: project.name,
            projectRoot: project.root,
            matchedCWD: cwd,
            links: links,
            diagnostics: catalogDiagnostics
        )
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
    /// 설정을 다시 읽은 뒤에도 **진행 중인 링크 선택을 유지해도 되는지** 판정한다.
    ///
    /// 프로젝트가 바뀌었거나 링크 목록(개수·순서·ID·URL)이 달라졌으면 false다.
    /// 이때는 이전 인덱스를 새 목록에 그대로 적용하지 않고 선택을 취소한다.
    public static func selectionSurvives(reloadFrom old: ProjectResolution?, to new: ProjectResolution?) -> Bool {
        guard let old, let new else { return false }
        guard old.projectID == new.projectID else { return false }
        guard old.links.count == new.links.count else { return false }
        return zip(old.links, new.links).allSatisfy { previous, next in
            previous.linkID == next.linkID && previous.url == next.url
        }
    }
}

// MARK: - 실행

public enum ProjectActionPlan: Equatable, Sendable {
    case openURL(URL)
    case reject(reason: String)

    public var rejectionReason: String? {
        if case .reject(let reason) = self { return reason }
        return nil
    }
}

public enum ProjectActionPlanner {
    /// 링크 열기 계획.
    ///
    /// 실행 자체는 `NSWorkspace`가 하고, 여기서는 **표시된 묶음과 선택한 항목이 일치하는지**만 검증한다.
    /// - 오류·확인 중이면 `state.isActionable`이 false라 실행을 막는다.
    /// - 프로젝트가 바뀌었거나 링크가 사라졌으면 거부한다(선택 중 갱신으로 다른 링크가 실행되는 것을 막는다).
    public static func plan(
        target: ProjectLinkTarget,
        in resolution: ProjectResolution?,
        state: DockState
    ) -> ProjectActionPlan {
        guard state.isActionable else {
            return .reject(reason: "지금은 실행할 수 없습니다: \(state.detail ?? "실행할 대상을 확인하는 중입니다")")
        }
        guard let resolution else {
            return .reject(reason: "현재 경로에 해당하는 프로젝트가 없습니다")
        }
        guard resolution.projectID == target.projectID else {
            return .reject(reason: "프로젝트가 바뀌었습니다. 다시 선택해 주세요")
        }
        guard resolution.links.contains(where: { $0.linkID == target.linkID && $0.url == target.url }) else {
            return .reject(reason: "선택한 링크를 현재 표시에서 찾을 수 없습니다")
        }
        guard ProjectCatalogValidator.isAllowedScheme(target.url), let url = URL(string: target.url) else {
            return .reject(reason: "허용되지 않는 링크입니다(http/https만): \(target.url)")
        }
        return .openURL(url)
    }
}
