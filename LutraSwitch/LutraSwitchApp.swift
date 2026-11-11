import AppKit
import ServiceManagement
import SwiftUI

@main
struct LutraSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Label("LutraSwitch", systemImage: "macwindow.on.rectangle")
        }

        Settings {
            SettingsView(controller: delegate.controller)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

private struct MenuContent: View {
    @Environment(\.openSettings) private var openSettings
    let controller: AppController

    var body: some View {
        if !controller.isListening {
            Text("窗口切换尚未启用")
            Divider()
        }
        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("退出 LutraSwitch") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

private struct SettingsView: View {
    let controller: AppController

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") {
                GeneralSettingsView(controller: controller)
            }
            Tab("关于", systemImage: "info.circle") {
                AboutSettingsView()
            }
        }
        .frame(width: 440)
    }
}

private struct GeneralSettingsView: View {
    let controller: AppController

    var body: some View {
        Form {
            Section("窗口切换快捷键") {
                LabeledContent("当前快捷键") {
                    Text(controller.shortcut.displayName)
                        .font(.body.monospaced())
                }
                HStack {
                    Button(controller.isRecording ? "取消录入" : "录入快捷键…") {
                        if controller.isRecording {
                            controller.endRecording()
                        } else {
                            controller.beginRecording()
                        }
                    }
                    Button("使用 ⌘Tab", action: controller.useCommandTab)
                        .help("接管 macOS 的应用切换快捷键")
                        .disabled(controller.shortcut.replacesSystemSwitcher)
                    Button("恢复默认快捷键") { controller.restoreShortcut() }
                }
                if controller.isRecording {
                    Text(controller.recordingError ?? "请按下组合键。按 Esc 取消。")
                        .foregroundStyle(.secondary)
                } else if controller.shortcut.replacesSystemSwitcher {
                    Text("⌘Tab 切换窗口，⌘⇧Tab 反向切换。")
                        .foregroundStyle(.secondary)
                }
            }

            LoginItemSettings()

            Section("Dock") {
                Toggle("悬停应用图标时预览窗口", isOn: Binding(
                    get: { controller.dockPreviewEnabled },
                    set: controller.setDockPreviewEnabled
                ))
            }

            Section("系统权限") {
                permissionRow(
                    "辅助功能", granted: controller.accessibilityAllowed,
                    button: "授权", action: controller.requestAccessibility
                )
                if !controller.isListening, controller.accessibilityAllowed,
                   controller.canIdentifyWindows, !controller.inputMonitoringAllowed {
                    permissionRow(
                        "输入监控", granted: false,
                        button: "授权", action: controller.requestInputMonitoring
                    )
                }
                permissionRow(
                    "屏幕录制", granted: controller.screenRecordingAllowed,
                    button: "授权缩略图", action: controller.requestScreenRecording
                )
                if !controller.canIdentifyWindows {
                    Text("此系统版本无法识别窗口，系统快捷键仍可使用。")
                        .foregroundStyle(.secondary)
                } else if !controller.accessibilityAllowed {
                    Text("辅助功能授权后即可启用快捷键。如果系统设置里已开启 LutraSwitch，请移除旧条目，再添加当前安装的版本。")
                        .foregroundStyle(.secondary)
                } else if controller.accessibilityAllowed, !controller.isListening {
                    Text("快捷键监听暂停。若刚授权，请退出并重新打开 LutraSwitch。")
                        .foregroundStyle(.secondary)
                } else if !controller.screenRecordingAllowed {
                    Text("屏幕录制用于显示窗口缩略图。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { controller.start() }
        .onDisappear { controller.endRecording() }
    }

    private func permissionRow(
        _ label: String, granted: Bool, button: String, action: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) {
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button(button, action: action)
            }
        }
    }
}

private struct LoginItemSettings: View {
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    private var isAdded: Bool { status == .enabled || status == .requiresApproval }

    var body: some View {
        Section("启动") {
            Toggle("添加到启动项", isOn: Binding(get: { isAdded }, set: updateRegistration))
            if status == .requiresApproval {
                LabeledContent("需要在系统设置中允许") {
                    Button("打开登录项…", action: SMAppService.openSystemSettingsLoginItems)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    private func updateRegistration(_ shouldAdd: Bool) {
        refreshStatus()
        guard shouldAdd != isAdded else { return }
        errorMessage = nil
        defer { refreshStatus() }

        do {
            if shouldAdd {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "无法更新启动项。\(error.localizedDescription)"
        }
    }
}

private struct AboutSettingsView: View {
    private let feedbackEmail = "lutratally@qq.com"

    var body: some View {
        Form {
            Section("LutraSwitch") {
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    LabeledContent("版本", value: version)
                }
                LabeledContent("反馈邮箱") {
                    if let destination = URL(string: "mailto:\(feedbackEmail)") {
                        Link(feedbackEmail, destination: destination)
                    } else {
                        Text(feedbackEmail)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
