import Foundation

struct AgentConfig: Codable {
    let name: String
    let host: String
    let port: Int
}

struct AppConfig: Codable {
    let agents: [String: AgentConfig]
    let token: String
    let pollInterval: Double?

    /// 内置默认值：本机真实拓扑，可被 ~/Library/Application Support/MagicSwitch/config.json 覆盖
    static let defaults = AppConfig(
        agents: [
            "studio": AgentConfig(name: "Mac Studio", host: "127.0.0.1", port: 19820),
            "mini": AgentConfig(name: "Mac mini", host: "Mac-mini.local", port: 19821),
        ],
        token: "CHANGE_ME",
        pollInterval: 5
    )

    static func load() -> AppConfig {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicSwitch/config.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return defaults
        }
        return cfg
    }
}

struct DeviceStatus: Codable {
    let addr: String
    let kind: String
    let connected: Bool
}

struct StatusResponse: Codable {
    let devices: [DeviceStatus]?
    let holding: Bool?
}

final class AgentClient {
    let id: String
    let config: AgentConfig
    private let token: String
    private let session: URLSession

    init(id: String, config: AgentConfig, token: String) {
        self.id = id
        self.config = config
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: cfg)
    }

    private func url(_ path: String) -> URL {
        URL(string: "http://\(config.host):\(config.port)\(path)")!
    }

    private func request(_ path: String, method: String) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Token")
        req.timeoutInterval = 3
        return req
    }

    func status() async throws -> StatusResponse {
        let (data, _) = try await session.data(for: request("/status", method: "GET"))
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    /// 返回 (全部成功, 错误描述)
    func connect() async throws -> (Bool, String?) {
        let (data, resp) = try await session.data(for: request("/connect", method: "POST"))
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode == 200, text)
    }

    func disconnect() async throws {
        let (_, _) = try await session.data(for: request("/disconnect", method: "POST"))
    }
}
