import SwiftUI
import ServiceManagement

@main
struct MagicSwitchApp: App {
    @StateObject private var switcher: Switcher

    init() {
        let s = Switcher()
        _switcher = StateObject(wrappedValue: s)
        s.startPolling()
        HotkeyManager.shared.onHotkey = { target in
            Task { await s.switch(to: target) }
        }
        HotkeyManager.shared.install()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(switcher: switcher)
                .frame(width: 280)
        } label: {
            switch switcher.holder {
            case .studio: Text("●S")
            case .mini: Text("●M")
            case .none: Text("○")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var switcher: Switcher

    private var holderText: String {
        switch switcher.holder {
        case .studio: return "Mac Studio"
        case .mini: return "Mac mini"
        case .none: return "未连接到任何机器"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "keyboard")
                    .foregroundStyle(.secondary)
                Text("键鼠当前 → \(holderText)")
                    .font(.headline)
            }

            ForEach(["studio", "mini"], id: \.self) { id in
                let offline = switcher.offline.contains(id)
                let isCurrent = switcher.holder == Switcher.Holder(rawValueCheck: id)
                Button {
                    let s = switcher
                    Task { await s.switch(to: id) }
                } label: {
                    HStack {
                        Image(systemName: iconFor(id))
                        Text("切到 \(switcher.displayName(id))")
                        Spacer()
                        if offline {
                            Image(systemName: "wifi.slash").foregroundStyle(.red)
                                .help("agent 离线")
                        } else if isCurrent {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(offline || switcher.busy || isCurrent)
                .keyboardShortcut(shortcutFor(id), modifiers: [])
            }

            if switcher.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(switcher.lastAction ?? "处理中…").font(.caption)
                }
            } else if let err = switcher.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let act = switcher.lastAction {
                Label(act, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            Divider()
            LaunchAtLoginToggle()
            Text("热键：⌃⌥S → Studio　⌃⌥M → mini")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Button("退出 MagicSwitch") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
    }

    private func iconFor(_ id: String) -> String {
        id == "studio" ? "display.trianglebadge.exclamationmark" : "display"
    }

    private func shortcutFor(_ id: String) -> KeyEquivalent {
        id == "studio" ? "1" : "2"
    }
}

extension Switcher.Holder {
    init(rawValueCheck id: String) {
        switch id {
        case "studio": self = .studio
        case "mini": self = .mini
        default: self = .none
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("登录时启动", isOn: Binding(
            get: { on },
            set: { newValue in
                on = newValue
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    on.toggle()
                }
            }
        ))
        .font(.caption)
    }
}
