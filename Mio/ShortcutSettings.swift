import AppKit
import Carbon
import Combine

struct AppShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    static let initial = AppShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), key: "M")

    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + key
    }

    func matches(_ other: AppShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

enum ShortcutAction: UInt32, CaseIterable {
    case toggleWindow = 1

    var title: String {
        switch self {
        case .toggleWindow: return "唤出 / 收起窗口"
        }
    }

    var storageKey: String {
        switch self {
        case .toggleWindow: return "windowShortcut"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .toggleWindow: return .initial
        }
    }
}

final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    @Published private(set) var shortcuts: [ShortcutAction: AppShortcut] = [:]
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var errorMessage: String?
    var onAction: ((ShortcutAction) -> Void)?

    var isRecording: Bool { recordingAction != nil }

    private let defaults: UserDefaults
    private var hotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4D696F48

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for action in ShortcutAction.allCases {
            if let data = defaults.data(forKey: action.storageKey) {
                shortcuts[action] = try? JSONDecoder().decode(AppShortcut?.self, from: data)
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    func shortcut(for action: ShortcutAction) -> AppShortcut? { shortcuts[action] }

    func start() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let settings = Unmanaged<ShortcutSettings>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == settings.signature,
                  let action = ShortcutAction(rawValue: identifier.id),
                  settings.hotKeys[action] != nil, !settings.isRecording else {
                return OSStatus(eventNotHandledErr)
            }
            settings.onAction?(action)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            errorMessage = "无法启用全局快捷键（\(status)）"
            return
        }
        registerCurrent()
    }

    func stop() {
        recordingAction = nil
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func beginRecording(_ action: ShortcutAction = .toggleWindow) {
        errorMessage = nil
        recordingAction = action
        unregister()
    }

    func cancelRecording() {
        guard isRecording else { return }
        recordingAction = nil
        errorMessage = nil
        registerCurrent()
    }

    func setShortcut(_ candidate: AppShortcut?, for action: ShortcutAction = .toggleWindow) {
        if let candidate, let duplicate = ShortcutAction.allCases.first(where: {
            $0 != action && shortcuts[$0].map { candidate.matches($0) } == true
        }) {
            cancelRecording()
            errorMessage = "此快捷键已用于「\(duplicate.title)」，请换一个组合键。"
            return
        }
        unregister()
        if let candidate, handler != nil {
            let status = register(candidate, for: action)
            guard status == noErr else {
                recordingAction = nil
                registerCurrent()
                errorMessage = "此快捷键不可用或已被占用，请换一个组合键。"
                return
            }
        }
        shortcuts[action] = candidate
        recordingAction = nil
        errorMessage = nil
        registerCurrent()
        if let data = try? JSONEncoder().encode(candidate) {
            defaults.set(data, forKey: action.storageKey)
        }
    }

    func record(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        if event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            setShortcut(nil, for: action)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            errorMessage = "请搭配 ⌘、⌃ 或 ⌥ 使用。"
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let key = special[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            errorMessage = "请选择字母、数字、方向键或空格等按键。"
            return
        }
        setShortcut(AppShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key), for: action)
    }

    private func register(_ shortcut: AppShortcut, for action: ShortcutAction) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: action.rawValue), GetApplicationEventTarget(), 0, &reference)
        if status == noErr { hotKeys[action] = reference }
        return status
    }

    private func registerCurrent() {
        guard handler != nil, !isRecording else { return }
        for action in ShortcutAction.allCases where hotKeys[action] == nil {
            guard let shortcut = shortcuts[action] else { continue }
            if register(shortcut, for: action) != noErr {
                errorMessage = "「\(action.title)」快捷键注册失败，可能已被占用，请重新设置。"
            }
        }
    }

    private func unregister() {
        for reference in hotKeys.values { UnregisterEventHotKey(reference) }
        hotKeys.removeAll()
    }
}
