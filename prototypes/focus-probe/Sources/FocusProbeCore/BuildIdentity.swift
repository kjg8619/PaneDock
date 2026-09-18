import Foundation

/// 실행 중인 빌드의 신원.
///
/// **제품 버전·빌드 번호·짧은 Git SHA를 구분**하고, **수정된 작업 트리로 만든 빌드를 깨끗한 커밋 빌드처럼 보이지 않게** 한다.
/// 형식은 순수 함수라 검사로 고정할 수 있다(코어에 두는 이유).
public struct BuildIdentity: Equatable, Sendable {
    /// 제품 버전(사람이 정한다). 빌드 스크립트도 이 값을 읽어 Info.plist에 넣는다.
    public static let productVersion = "0.2a"

    public var productVersion: String
    /// 빌드 번호(저장소 커밋 수). 번들에 기록되지 않았으면 nil.
    public var buildNumber: String?
    /// 짧은 Git SHA. 번들에 기록되지 않았으면 nil.
    public var gitSHA: String?
    /// 빌드 시점에 작업 트리가 수정돼 있었는가.
    public var isDirtyTree: Bool
    /// 번들 정보를 읽었는가(개발용 실행 파일은 번들이 없다).
    public var hasBundleInfo: Bool

    public init(
        productVersion: String = BuildIdentity.productVersion,
        buildNumber: String? = nil,
        gitSHA: String? = nil,
        isDirtyTree: Bool = false,
        hasBundleInfo: Bool = false
    ) {
        self.productVersion = productVersion
        self.buildNumber = buildNumber
        self.gitSHA = gitSHA
        self.isDirtyTree = isDirtyTree
        self.hasBundleInfo = hasBundleInfo
    }

    /// 앱 번들의 정보 사전에서 만든다(개발용 실행 파일이면 사전이 비어 있다).
    public static func from(infoDictionary: [String: Any]?) -> BuildIdentity {
        guard let info = infoDictionary, !info.isEmpty else {
            return BuildIdentity(hasBundleInfo: false)
        }
        let version = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces)
        let build = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces)
        let sha = (info["PaneDockGitSHA"] as? String)?.trimmingCharacters(in: .whitespaces)
        let dirty = (info["PaneDockGitDirty"] as? String)?.trimmingCharacters(in: .whitespaces)
        return BuildIdentity(
            productVersion: (version?.isEmpty == false ? version! : BuildIdentity.productVersion),
            buildNumber: (build?.isEmpty == false ? build : nil),
            gitSHA: (sha?.isEmpty == false ? sha : nil),
            isDirtyTree: dirty == "1",
            hasBundleInfo: true
        )
    }

    /// 사람이 읽는 한 줄. **수정된 트리로 만든 빌드는 그 사실을 숨기지 않는다.**
    public var displayText: String {
        guard hasBundleInfo else {
            return "\(productVersion) · 개발 빌드(번들 정보 없음)"
        }
        var parts: [String] = [productVersion]
        if let buildNumber { parts.append("빌드 \(buildNumber)") }
        if let gitSHA { parts.append(gitSHA) }
        var text = parts.joined(separator: " · ")
        if isDirtyTree { text += " · 수정된 트리" }
        return text
    }

    /// 로그 한 줄에 쓰는 형태(`key=value`).
    public var logText: String {
        var fields = ["version=\(productVersion)"]
        fields.append("build=\(buildNumber ?? "-")")
        fields.append("sha=\(gitSHA ?? "-")")
        fields.append("dirty=\(isDirtyTree)")
        fields.append("bundle=\(hasBundleInfo)")
        return fields.joined(separator: " ")
    }
}
