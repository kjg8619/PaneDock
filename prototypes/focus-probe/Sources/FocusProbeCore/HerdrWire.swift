import Foundation

/// 최소 JSON 값 타입. herdr 요청 파라미터는 `{}`, `{"pane_id":...}`,
/// `{"subscriptions":[{"type":...}]}` 세 형태뿐이라 이 정도로 충분하다.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }
}

/// 요청 프레임. herdr 소켓은 newline-delimited JSON을 쓴다.
public struct HerdrRequest: Encodable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue

    public init(id: String, method: String, params: JSONValue = .object([:])) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct HerdrErrorDTO: Decodable, Equatable, Sendable {
    public var code: String?
    public var message: String?
}

/// 응답 프레임. 성공은 `result`, 실패는 `error`가 채워진다.
public struct HerdrResponse<Result: Decodable>: Decodable {
    public var id: String?
    public var result: Result?
    public var error: HerdrErrorDTO?
}

public struct PaneRecordDTO: Decodable, Equatable, Sendable {
    public var paneID: String
    public var workspaceID: String
    public var tabID: String
    public var terminalID: String?
    public var cwd: String?
    public var foregroundCWD: String?
    public var focused: Bool
    public var revision: Int?
    public var title: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case terminalID = "terminal_id"
        case cwd
        case foregroundCWD = "foreground_cwd"
        case focused
        case revision
        case title = "terminal_title_stripped"
    }
}

public struct PaneListResult: Decodable, Sendable {
    public var panes: [PaneRecordDTO]
}

public struct PaneGetResult: Decodable, Sendable {
    public var pane: PaneRecordDTO
}

public struct SessionSnapshotDTO: Decodable, Sendable {
    public var focusedPaneID: String?
    public var focusedTabID: String?
    public var focusedWorkspaceID: String?
    public var version: String?
    public var protocolVersion: Int?
    public var panes: [PaneRecordDTO]

    enum CodingKeys: String, CodingKey {
        case focusedPaneID = "focused_pane_id"
        case focusedTabID = "focused_tab_id"
        case focusedWorkspaceID = "focused_workspace_id"
        case version
        case protocolVersion = "protocol"
        case panes
    }
}

public struct SessionSnapshotResult: Decodable, Sendable {
    public var snapshot: SessionSnapshotDTO
}

public struct PingResult: Decodable, Sendable {
    public var type: String?
    public var version: String?
    public var protocolVersion: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case version
        case protocolVersion = "protocol"
    }
}

public struct SubscribeResult: Decodable, Sendable {
    public var type: String?
}

/// 구독 이벤트 프레임. 페이로드 형태가 이벤트마다 다르므로
/// 이벤트 이름과 pane 식별자만 관대하게 꺼낸다.
/// 프로토타입은 이벤트를 **갱신 신호로만** 쓰고 실제 값은 다시 조회한다.
public struct HerdrEvent: Equatable, Sendable {
    /// 서버가 보낸 이름 그대로.
    public var name: String
    public var paneID: String?

    public init(name: String, paneID: String?) {
        self.name = name
        self.paneID = paneID
    }

    /// 이름 표기가 계열마다 다르다.
    ///
    /// 구독 요청은 점 표기(`pane.updated`)를 쓰지만, 실제로 발행되는 프레임은
    /// 밑줄 표기(`pane_updated`)였다(설치본에서 직접 관측). 반대로
    /// `SubscriptionEventKind`는 점 표기를 쓴다. 두 표기를 하나로 맞춰 비교한다.
    public var normalizedName: String {
        name.replacingOccurrences(of: "_", with: ".")
    }
}

struct HerdrEventFrame: Decodable {
    var event: String
    var data: JSONValue?

    enum CodingKeys: String, CodingKey { case event, data }

    /// `data` 안에서 pane 식별자를 찾는다. `data.pane_id` 또는 `data.pane.pane_id`.
    var paneID: String? {
        guard case .object(let root)? = data else { return nil }
        if case .string(let id)? = root["pane_id"] { return id }
        if case .object(let pane)? = root["pane"], case .string(let id)? = pane["pane_id"] { return id }
        return nil
    }
}
