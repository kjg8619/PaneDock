import CoreGraphics
import Foundation

/// Dock 호출 단축키 선택지. 키코드 매핑은 앱(AppKit/Carbon) 쪽에 있고, 여기에는 **설정 값**만 둔다.
///
/// 기본값은 `controlOptionCommandD`다. 전역 단축키는 다른 앱에서 그 조합을 가져가므로,
/// 흔히 쓰이는 짧은 조합(예: ⌘D)을 피하고 수정자 3개 조합을 기본으로 삼았다.
public enum HotKeyChoice: String, Codable, Sendable, CaseIterable {
    case controlOptionCommandD
    case optionCommandD
    case controlOptionD
    case disabled

    public var displayName: String {
        switch self {
        case .controlOptionCommandD: return "⌃⌥⌘D"
        case .optionCommandD: return "⌥⌘D"
        case .controlOptionD: return "⌃⌥D"
        case .disabled: return "사용 안 함"
        }
    }
}

public struct StoredOrigin: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 로컬 설정. 스키마 버전을 명시한다.
///
/// **저장하지 않는 것:** 현재 pane ID, 실시간 경로, 잠금 상태.
/// 이것들은 재시작하면 새로 조회한 유효한 작업 정보로 다시 정해진다.
public struct PaneDockSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    /// 모든 필드를 **없어도 기본값으로** 읽는다.
    ///
    /// 이전 설정 파일에 새 필드(예: `appearance`)가 없어도 **기존 모습으로 그대로 실행**돼야 한다.
    /// 합성 디코더를 쓰면 필드가 하나 늘 때마다 예전 파일이 "손상"으로 보인다(V16에서 실제로 발생).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = ((try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil) ?? 1
        appearance = ((try? container.decodeIfPresent(DockAppearance.self, forKey: .appearance)) ?? nil) ?? .default
        windowOrigin = (try? container.decodeIfPresent(StoredOrigin.self, forKey: .windowOrigin)) ?? nil
        hotKey = ((try? container.decodeIfPresent(HotKeyChoice.self, forKey: .hotKey)) ?? nil) ?? .controlOptionCommandD
        hotKeyEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled)) ?? nil) ?? true
    }


    public var schemaVersion: Int
    public var windowOrigin: StoredOrigin?
    public var hotKey: HotKeyChoice
    public var hotKeyEnabled: Bool
    /// Dock 외형(크기·항목 표시·색상 모드). **없던 파일에서는 기본 외형**으로 동작한다.
    public var appearance: DockAppearance

    public init(
        schemaVersion: Int = PaneDockSettings.currentSchemaVersion,
        appearance: DockAppearance = .default,
        windowOrigin: StoredOrigin? = nil,
        hotKey: HotKeyChoice = .controlOptionCommandD,
        hotKeyEnabled: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.appearance = appearance
        self.windowOrigin = windowOrigin
        self.hotKey = hotKey
        self.hotKeyEnabled = hotKeyEnabled
    }
}

public enum SettingsLoadOutcome: Equatable, Sendable {
    /// 파일이 없다. 기본값으로 시작한다.
    case fresh
    case loaded
    /// 읽을 수 없거나 형식이 깨졌다. 원본은 백업으로 보존하고 기본값으로 시작한다.
    case corrupt(backupPath: String?)
    /// 이 앱이 모르는(더 새로운) 스키마 버전이다. **파일을 건드리지 않고** 기본값으로 시작한다.
    case unsupportedVersion(found: Int)

    public var label: String {
        switch self {
        case .fresh: return "fresh"
        case .loaded: return "loaded"
        case .corrupt(let path): return "corrupt(backup=\(path ?? "-"))"
        case .unsupportedVersion(let found): return "unsupportedVersion(\(found))"
        }
    }
}

/// 설정 저장소.
///
/// `url == nil`이면 **메모리 전용**이다. 가짜 데이터 모드와 자동 검사는 이 모드를 써서
/// 실제 사용자 설정 파일을 절대 건드리지 않는다.
public final class SettingsStore {
    public private(set) var outcome: SettingsLoadOutcome = .fresh
    public private(set) var settings = PaneDockSettings()

    private let url: URL?

    public init(url: URL?) {
        self.url = url
        load()
    }

    /// 미래 버전 파일은 덮어쓰지 않는다.
    public var canWrite: Bool {
        if case .unsupportedVersion = outcome { return false }
        return true
    }

    /// 쓸 수 없을 때 **이유**. 쓸 수 있으면 nil. UI가 "왜 저장이 안 되는지"를 그대로 보여줄 수 있게 한다.
    public var writeBlockedReason: String? {
        if case .unsupportedVersion(let found) = outcome {
            return "설정 파일이 더 새로운 버전(v\(found))이라 덮어쓰지 않습니다"
        }
        return nil
    }

    public var isMemoryOnly: Bool { url == nil }

    public var fileURL: URL? { url }

    // MARK: - 로드

    public func load() {
        guard let url else {
            outcome = .fresh
            settings = PaneDockSettings()
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            outcome = .fresh
            settings = PaneDockSettings()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            outcome = .corrupt(backupPath: nil)
            settings = PaneDockSettings()
            return
        }

        do {
            let decoded = try JSONDecoder().decode(PaneDockSettings.self, from: data)
            guard decoded.schemaVersion <= PaneDockSettings.currentSchemaVersion else {
                outcome = .unsupportedVersion(found: decoded.schemaVersion)
                settings = PaneDockSettings()
                return
            }
            outcome = .loaded
            settings = decoded
        } catch {
            // 손상: 원본을 백업으로 옮겨 보존한다. 조용히 덮어쓰지 않는다.
            let backup = backUpCorruptFile(at: url)
            outcome = .corrupt(backupPath: backup)
            settings = PaneDockSettings()
        }
    }

    private func backUpCorruptFile(at url: URL) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup.path
        } catch {
            return nil
        }
    }

    // MARK: - 변경

    /// 값을 바꾸고 **파일에 쓴다.** 쓰기 결과를 돌려준다(실패를 성공으로 보고하지 않기 위해).
    @discardableResult
    public func update(_ mutate: (inout PaneDockSettings) -> Void) -> Bool {
        var next = settings
        mutate(&next)
        next.schemaVersion = PaneDockSettings.currentSchemaVersion
        settings = next
        return save()
    }

    public func resetWindowOrigin() {
        update { $0.windowOrigin = nil }
    }

    /// 파일에 쓴다. **성공 여부를 돌려준다**(호출자가 "저장했습니다"를 잘못 띄우지 않게).
    @discardableResult
    public func save() -> Bool {
        guard let url else { return true }   // 메모리 전용: 쓸 파일이 없다
        guard canWrite else { return false } // 지원하지 않는 버전 파일은 덮어쓰지 않는다
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 원자적 쓰기: 임시 파일에 쓰고 교체한다.
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            // 저장 실패는 치명적이지 않다. 다음 변경에서 다시 시도한다. 다만 **성공으로 보고하지는 않는다.**
            return false
        }
    }
}

/// 저장된 창 좌표가 지금 화면에 보이는지 판정하고, 아니면 보이는 위치로 보정한다.
///
/// 화면 구성이 바뀌었거나(모니터 분리) 해상도가 달라진 경우를 위한 것이다.
public enum WindowPlacement {
    /// 창이 최소 이만큼은 보여야 "보이는 위치"로 인정한다.
    public static let minimumVisibleWidth: CGFloat = 80
    public static let minimumVisibleHeight: CGFloat = 40

    public static func clamp(
        origin: CGPoint,
        size: CGSize,
        screens: [CGRect],
        fallback: CGRect
    ) -> CGPoint {
        let windowRect = CGRect(origin: origin, size: size)
        let isVisible = screens.contains { screen in
            let intersection = screen.intersection(windowRect)
            return !intersection.isNull
                && intersection.width >= minimumVisibleWidth
                && intersection.height >= minimumVisibleHeight
        }
        if isVisible { return origin }

        let maxX = max(fallback.minX, fallback.maxX - size.width)
        let maxY = max(fallback.minY, fallback.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, fallback.minX), maxX),
            y: min(max(origin.y, fallback.minY), maxY)
        )
    }

    /// 기본 위치: 기준 화면의 왼쪽 아래 모서리에서 조금 안쪽.
    public static func defaultOrigin(in fallback: CGRect) -> CGPoint {
        CGPoint(x: fallback.minX + 24, y: fallback.minY + 24)
    }
}
