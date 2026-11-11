import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: ShortcutSettings
    @StateObject private var loginItem = LoginItemSettings()

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动", isOn: Binding(
                    get: { loginItem.isRegistered },
                    set: { enabled in Task { await loginItem.setEnabled(enabled) } }
                ))
                .disabled(loginItem.isUpdating)
                if loginItem.status == .requiresApproval {
                    Text("需要在系统设置中允许 Mio 登录时启动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开登录项设置") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(settings: settings, shortcutAction: action)
                            .frame(width: 150, height: 28)
                        Button {
                            settings.setShortcut(nil, for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(settings.shortcut(for: action) == nil && settings.recordingAction != action)
                        .help("清除快捷键")
                        .accessibilityLabel("清除\(action.title)快捷键")
                        Button {
                            settings.setShortcut(action.defaultShortcut, for: action)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(settings.shortcut(for: action) == action.defaultShortcut && settings.recordingAction != action)
                        .help("恢复默认快捷键")
                        .accessibilityLabel("恢复\(action.title)默认快捷键")
                    }
                }
                if settings.isRecording {
                    Text("按下组合键，Esc 取消，Delete 清除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = settings.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("全局快捷键")
            }
            Section("音量") {
                Stepper(value: Binding(
                    get: { settings.volumeStepPercent },
                    set: { settings.setVolumeStep($0) }
                ), in: 0.5 ... 5, step: 0.5) {
                    LabeledContent("每次调整", value: "\(settings.volumeStepPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .padding(.vertical, 8)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onDisappear { settings.cancelRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            settings.cancelRecording()
        }
    }
}

@MainActor
private final class LoginItemSettings: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    // A pending registration stays switchable so the user can cancel it.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "无法\(enabled ? "开启" : "关闭")登录时启动：\(error.localizedDescription)"
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var settings: ShortcutSettings
    let shortcutAction: ShortcutAction

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.settings = settings
        button.shortcutAction = shortcutAction
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.target = button
        button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel("录制\(shortcutAction.title)快捷键")
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = settings.recordingAction == shortcutAction ? "请按下快捷键…" : (settings.shortcut(for: shortcutAction)?.display ?? "录制快捷键")
    }

    final class RecorderButton: NSButton {
        weak var settings: ShortcutSettings?
        var shortcutAction: ShortcutAction = .toggleWindow
        override var acceptsFirstResponder: Bool { true }

        @objc func startRecording() {
            window?.makeFirstResponder(self)
            settings?.beginRecording(shortcutAction)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard settings?.recordingAction == shortcutAction else { return super.performKeyEquivalent(with: event) }
            settings?.record(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if settings?.isRecording == true { settings?.record(event) }
            else { super.keyDown(with: event) }
        }

        override func resignFirstResponder() -> Bool {
            if settings?.recordingAction == shortcutAction { settings?.cancelRecording() }
            return super.resignFirstResponder()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil && settings?.recordingAction == shortcutAction { settings?.cancelRecording() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
