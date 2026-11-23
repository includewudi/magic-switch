# MagicSwitch 设计文档

日期：2026-11-23
状态：已通过用户评审

## 背景与目标

用户有三台 Mac：MacBook Pro（本机）、Mac Studio、Mac mini。只有一台显示器，
经常在 Studio 和 mini 之间手动拔插换接。要求：

- **双光标同时使用**：MacBook 用自带键盘/触控板，Apple Magic 蓝牙键鼠直连
  显示器所接的机器（Studio 或 mini），两台机器各有光标、互不干扰。
- **切换要快**：换插显示器后，一键（或热键）把 Magic 键鼠的蓝牙连接切到
  对应机器，秒级完成。
- MacBook 作为"控制中心"，上面放一个菜单栏 app 发起切换。

软件 KVM（Deskflow/Universal Control）因"单一输入焦点"模型不满足双光标
需求，被排除；Apple Magic 键鼠没有多设备通道硬件按键，官方切换需进蓝牙
菜单，故用 blueutil 自动化。

## 架构

```
┌─ MacBook Pro ───────────────────────┐
│  MagicSwitch.app（MenuBarExtra）     │
│   ├ 图标随状态变化（●S / ●M / ○）     │
│   ├ [→ Studio]  [→ Mac mini] 按钮    │
│   └ 全局热键 ⌃⌥S / ⌃⌥M              │
└─────┬───────────────────┬───────────┘
      │ HTTP + token      │ HTTP + token
┌─────▼────────┐   ┌──────▼────────┐
│ Mac Studio   │   │ Mac mini      │
│ bt-agent     │   │ bt-agent      │
│ (launchd常驻)│   │ (launchd常驻) │
│ → blueutil   │   │ → blueutil    │
└──────────────┘   └───────────────┘
```

选型理由（方案 B：小 Agent）：mini 的 SSH 公钥认证异常（sshd 拒绝，原因
未明），agent 方式绕开 SSH 依赖；HTTP 毫秒级响应；可实时轮询状态；未来
扩展（DDC 切显示器输入源等）走同一通道。

## 组件

### bt-agent（Go 单二进制，stdlib only）

- 监听 `:19821`，仅局域网
- 鉴权：`X-Token` 头与配置比对
- 接口：
  - `GET /status` → `{"keyboard":bool,"mouse":bool}`（blueutil --is-connected）
  - `POST /connect` → 并行 blueutil --connect 键+鼠，重试 2 次
  - `POST /disconnect` → blueutil --disconnect 键+鼠
- 配置 `/usr/local/etc/bt-agent.json`：token、设备 MAC 列表、端口
- launchd：RunAtLoad + KeepAlive

### MagicSwitch.app（SwiftUI MenuBarExtra）

- 菜单栏图标：●S / ●M / ○ / 离线
- 下拉：当前持有者 + 两个切换按钮 + 登录启动开关（SMAppService）
- 热键：Carbon RegisterEventHotKey，⌃⌥S / ⌃⌥M
- 配置：`~/Library/Application Support/MagicSwitch/config.json`
- 非沙盒，ad-hoc 签名本地使用

## 切换流程

1. app 查两台 /status 确定当前持有者
2. 调持有者 /disconnect
3. 调目标 /connect
4. 复查 /status，刷新图标
5. 状态轮询：每 5 秒

## 错误处理

| 场景 | 行为 |
|---|---|
| 未配对 | connect 失败 → 提示先在该机器配对 |
| agent 离线 | 按钮置灰，图标标离线 |
| 断开成功连接失败 | 自动回连原机器，防键鼠悬空 |
| token 不匹配 | 401 → 提示核对配置 |
| 两台竞态 | 蓝牙单主机，以 /status 实查为准 |

## 部署拓扑

- Studio：SSH 可达（~/.ssh/id_ed25519_nopass, wudis@wudisdeMac-Studio.local）
- mini：SSH 公钥异常；文件经 GitHub（走本机 7897 代理拉取）+ tmux 通道下发
  配置/命令；Mac mini 用户 mac@192.168.10.187
- 前提（用户物理操作一次性）：Magic 键鼠与 Studio、mini 各配对一次

## 代码组织

```
magic-switch/
├── agent/        # Go bt-agent
├── app/          # SwiftUI MagicSwitch
└── docs/plans/   # 设计文档
```

## 验收标准

显示器换插到 Studio → 按 ⌃⌥S → 1 秒内键鼠切到 Studio，图标变 ●S；
反向同理。双机可同时各自操作（MacBook 触控板 + 目标机 Magic 键鼠）。
