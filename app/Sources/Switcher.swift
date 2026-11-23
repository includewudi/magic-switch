import Foundation
import Combine

/// 切换编排器：轮询状态 + 执行切换（含失败回滚）
final class Switcher: ObservableObject {
    enum Holder: Equatable {
        case studio, mini, none
    }

    @Published var holder: Holder = .none
    @Published var offline: Set<String> = []      // 不可达的 agent id
    @Published var busy = false
    @Published var lastError: String?
    @Published var lastAction: String?

    private let config: AppConfig
    private var clients: [String: AgentClient] = [:]
    private var pollTask: Task<Void, Never>?

    init(config: AppConfig = .load()) {
        self.config = config
        for (id, ac) in config.agents {
            clients[id] = AgentClient(id: id, config: ac, token: config.token)
        }
    }

    var interval: Double { config.pollInterval ?? 5 }

    func displayName(_ id: String) -> String {
        config.agents[id]?.name ?? id
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let iv = self?.interval ?? 5
                try? await Task.sleep(nanoseconds: UInt64(iv * 1_000_000_000))
            }
        }
    }

    private func holderFor(_ id: String) -> Holder {
        switch id {
        case "studio": return .studio
        case "mini": return .mini
        default: return .none
        }
    }

    /// 并发查询所有 agent，刷新 holder / offline
    func poll() async {
        var newHolder: Holder = .none
        var failed: Set<String> = []
        for (id, client) in clients {
            do {
                let st = try await client.status()
                if st.holding == true, newHolder == .none {
                    newHolder = holderFor(id)
                }
            } catch {
                failed.insert(id)
            }
        }
        await MainActor.run {
            self.offline = failed
            self.holder = newHolder
        }
    }

    /// 核心切换：断开持有者 → 连接目标 → 复查；连接失败自动回滚
    func `switch`(to target: String) async {
        guard !busy else { return }
        guard let targetClient = clients[target] else { return }
        await MainActor.run {
            self.busy = true
            self.lastError = nil
            self.lastAction = "正在切换到 \(displayName(target))…"
        }

        // 找出当前持有者
        var previous: String?
        for (id, client) in clients {
            if let st = try? await client.status(), st.holding == true {
                previous = id
            }
        }

        // 1. 断开持有者
        if let prev = previous, prev != target {
            try? await clients[prev]?.disconnect()
        }

        // 2. 连接目标
        var ok = false
        var errText = "未知错误"
        do {
            let (all, text) = try await targetClient.connect()
            ok = all
            if !all {
                if let t = text, !t.isEmpty {
                    errText = String(t.prefix(200))
                } else {
                    errText = "部分设备未连上"
                }
            }
        } catch {
            errText = "agent 不可达：\(error.localizedDescription)"
        }

        // 3. 失败回滚：重新连回原持有者，防止键鼠悬空
        var rolledBack = false
        if !ok, let prev = previous, prev != target {
            if let (back, _) = try? await clients[prev]!.connect(), back {
                rolledBack = true
            }
        }

        await poll()
        await MainActor.run {
            self.busy = false
            if ok {
                self.lastAction = "已切换到 \(displayName(target)) ✓"
                self.lastError = nil
            } else {
                self.lastAction = nil
                var msg = "连接 \(displayName(target)) 失败：\(errText)"
                if rolledBack {
                    msg += "（已自动回连 \(displayName(previous ?? ""))）"
                }
                self.lastError = msg
            }
        }
    }
}
