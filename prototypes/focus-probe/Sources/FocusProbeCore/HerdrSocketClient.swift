import Darwin
import Foundation

/// 소켓 연결 실패. 연결 상태 표시로 바로 매핑된다.
public enum HerdrConnectionFailure: Error, Equatable {
    /// 소켓 파일이 없다 → herdr 서버가 실행 중이 아니다.
    case notFound(String)
    /// 리스너가 없다 → 서버가 죽었다.
    case refused(String)
    /// 권한 거부.
    case denied(String)
    case other(String)

    public var connectionStatus: ConnectionStatus {
        switch self {
        case .notFound: return .unavailable
        case .refused: return .refused
        case .denied: return .denied
        case .other: return .unavailable
        }
    }

    public var diagnosticText: String {
        switch self {
        case .notFound(let path): return "socket not found: \(path)"
        case .refused(let path): return "connection refused: \(path)"
        case .denied(let path): return "permission denied: \(path)"
        case .other(let message): return message
        }
    }
}

/// 요청/응답 실패.
public enum HerdrProtocolFailure: Error, Equatable {
    case timeout(String)
    case closed(String)
    case malformed(String)
    case server(code: String, message: String)

    public var diagnosticText: String {
        switch self {
        case .timeout(let method): return "timeout waiting for \(method)"
        case .closed(let method): return "connection closed during \(method)"
        case .malformed(let detail): return "malformed response: \(detail)"
        case .server(let code, let message): return "server error \(code): \(message)"
        }
    }
}

/// herdr 소켓 클라이언트.
///
/// 관측한 서버 동작에 맞춰 **요청 1건당 연결 1개**를 쓴다.
/// 구독은 별도 전용 연결에서만 유지한다(같은 연결에 두 번째 요청을 보내면 서버가 닫는다).
///
/// 이 클라이언트는 `caller_pane_id`를 절대 보내지 않는다.
/// 호출자 컨텍스트를 실어 보내면 "호출한 pane"이 돌아와 포커스 pane을 놓친다.
public final class HerdrSocketClient {
    public let socketPath: String
    private let timeoutMilliseconds: Int32

    public init(socketPath: String, timeout: TimeInterval = 2.0) {
        self.socketPath = socketPath
        self.timeoutMilliseconds = Int32(max(0.05, timeout) * 1000)
    }

    // MARK: - 연결

    public func dial() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrConnectionFailure.other("socket() failed errno=\(errno)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HerdrConnectionFailure.other("socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, length)
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Self.classify(errno: code, path: socketPath)
        }
        return fd
    }

    static func classify(errno code: Int32, path: String) -> HerdrConnectionFailure {
        switch code {
        case ENOENT: return .notFound(path)
        case ECONNREFUSED: return .refused(path)
        case EACCES, EPERM: return .denied(path)
        default: return .other("connect failed errno=\(code) path=\(path)")
        }
    }

    // MARK: - 요청/응답

    public func request<Result: Decodable>(
        _ method: String,
        params: JSONValue = .object([:]),
        as type: Result.Type
    ) throws -> Result {
        let fd = try dial()
        defer { close(fd) }
        var buffer = Data()
        let requestID = "focus-probe-\(UUID().uuidString.prefix(8))"
        let frame = try JSONEncoder().encode(HerdrRequest(id: requestID, method: method, params: params))
        try write(fd: fd, data: frame + Data([0x0A]), method: method)
        let line = try readLine(fd: fd, buffer: &buffer, method: method)

        let response: HerdrResponse<Result>
        do {
            response = try JSONDecoder().decode(HerdrResponse<Result>.self, from: Data(line.utf8))
        } catch {
            throw HerdrProtocolFailure.malformed("\(method): \(error)")
        }
        if let serverError = response.error {
            throw HerdrProtocolFailure.server(
                code: serverError.code ?? "unknown",
                message: serverError.message ?? ""
            )
        }
        guard let result = response.result else {
            throw HerdrProtocolFailure.malformed("\(method): no result")
        }
        return result
    }

    // MARK: - 구독

    /// 전용 구독 연결을 연다. ack를 받은 뒤에만 반환한다.
    public func subscribe(types: [String]) throws -> HerdrSubscription {
        let fd = try dial()
        var buffer = Data()
        let subscriptions = JSONValue.array(types.map { .object(["type": .string($0)]) })
        let params = JSONValue.object(["subscriptions": subscriptions])
        let requestID = "focus-probe-sub-\(UUID().uuidString.prefix(8))"
        let frame = try JSONEncoder().encode(
            HerdrRequest(id: requestID, method: "events.subscribe", params: params)
        )
        do {
            try write(fd: fd, data: frame + Data([0x0A]), method: "events.subscribe")
            _ = try readLine(fd: fd, buffer: &buffer, method: "events.subscribe")
        } catch {
            close(fd)
            throw error
        }
        return HerdrSubscription(fd: fd, timeoutMilliseconds: timeoutMilliseconds)
    }

    // MARK: - 저수준 I/O

    private func write(fd: Int32, data: Data, method: String) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            try wait(fd: fd, events: Int16(POLLOUT), method: method)
            let written = bytes.withUnsafeBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.write(fd, base + offset, bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw HerdrProtocolFailure.closed(method)
            }
        }
    }

    private func readLine(fd: Int32, buffer: inout Data, method: String) throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            try wait(fd: fd, events: Int16(POLLIN), method: method)
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw HerdrProtocolFailure.closed(method)
            } else if errno == EINTR {
                continue
            } else {
                throw HerdrProtocolFailure.closed(method)
            }
        }
    }

    private func wait(fd: Int32, events: Int16, method: String) throws {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, timeoutMilliseconds)
        if result == 0 { throw HerdrProtocolFailure.timeout(method) }
        if result < 0 && errno != EINTR { throw HerdrProtocolFailure.closed(method) }
    }
}

/// 구독 전용 연결. 이벤트 프레임을 한 줄씩 읽는다.
public final class HerdrSubscription {
    private let fd: Int32
    private let timeoutMilliseconds: Int32
    private var buffer = Data()

    fileprivate init(fd: Int32, timeoutMilliseconds: Int32) {
        self.fd = fd
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    deinit { close() }

    public func close() {
        Darwin.close(fd)
    }

    /// 다음 이벤트를 기다린다. 타임아웃이면 nil을 돌려준다(안전 재확인 주기용).
    public func nextEvent() throws -> HerdrEvent? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                return try HerdrSubscription.decode(line: Data(line))
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, timeoutMilliseconds)
            if result == 0 { return nil }
            if result < 0 {
                if errno == EINTR { continue }
                throw HerdrProtocolFailure.closed("events.subscribe")
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw HerdrProtocolFailure.closed("events.subscribe")
            } else if errno != EINTR {
                throw HerdrProtocolFailure.closed("events.subscribe")
            }
        }
    }

    /// 이벤트 프레임을 디코딩한다. 형태가 다르면 malformed로 알린다.
    /// (이벤트 페이로드는 이벤트마다 달라 이벤트 이름과 pane 식별자만 꺼낸다.)
    static func decode(line: Data) throws -> HerdrEvent {
        // 구독 ack나 무관한 응답이 섞여 오면 이벤트가 아니다.
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HerdrProtocolFailure.malformed("event frame is not a JSON object")
        }
        guard let name = object["event"] as? String else {
            throw HerdrProtocolFailure.malformed("event frame has no 'event' field")
        }
        var paneID: String?
        if let data = object["data"] as? [String: Any] {
            if let direct = data["pane_id"] as? String {
                paneID = direct
            } else if let pane = data["pane"] as? [String: Any] {
                paneID = pane["pane_id"] as? String
            }
        }
        return HerdrEvent(name: name, paneID: paneID)
    }
}
