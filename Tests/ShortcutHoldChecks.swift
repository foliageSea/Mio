import AppKit
import Carbon

@main
struct ShortcutHoldChecks {
    static func main() {
        _ = NSApplication.shared
        let domain = "MioShortcutHoldChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ShortcutSettings(defaults: defaults)
        for action in ShortcutAction.allCases { settings.setShortcut(nil, for: action) }
        settings.start()
        defer { settings.stop() }
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let up = AppShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: modifiers, key: "L")
        settings.setShortcut(AppShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: modifiers, key: "K"))
        settings.setShortcut(up, for: .volumeUp)
        settings.setShortcut(AppShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: modifiers, key: "J"), for: .volumeDown)
        precondition(settings.errorMessage == nil)
        var actions: [ShortcutAction] = []
        settings.onAction = { actions.append($0) }

        func send(_ action: ShortcutAction, pressed: Bool) {
            var event: EventRef?
            let kind = UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased)
            precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
            defer { ReleaseEvent(event!) }
            var id = EventHotKeyID(signature: 0x4D696F48, id: action.rawValue)
            precondition(SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
            precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
        }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func staysStopped() {
            let count = actions.count
            pump(0.5)
            precondition(actions.count == count, "Unexpected repeat after cancellation")
        }

        send(.volumeUp, pressed: true)
        precondition(actions == [.volumeUp])
        send(.volumeUp, pressed: false)
        staysStopped()
        actions.removeAll()
        send(.volumeDown, pressed: true)
        send(.volumeDown, pressed: true)
        precondition(actions == [.volumeDown], "Duplicate Carbon presses must not double adjustment")
        pump(0.62)
        precondition(actions.count >= 3 && actions.allSatisfy { $0 == .volumeDown })
        send(.volumeDown, pressed: false)
        staysStopped()

        actions.removeAll()
        send(.toggleWindow, pressed: true)
        send(.toggleWindow, pressed: true)
        pump(0.5)
        precondition(actions == [.toggleWindow])
        send(.toggleWindow, pressed: false)
        send(.toggleWindow, pressed: true)
        precondition(actions == [.toggleWindow, .toggleWindow])
        send(.toggleWindow, pressed: false)

        actions.removeAll()
        send(.volumeUp, pressed: true)
        pump(0.42)
        let switchedAt = actions.count
        send(.volumeDown, pressed: true)
        send(.volumeUp, pressed: false)
        pump(0.5)
        precondition(actions.count > switchedAt + 1)
        precondition(actions.dropFirst(switchedAt).allSatisfy { $0 == .volumeDown })
        send(.volumeDown, pressed: false)
        staysStopped()

        send(.volumeUp, pressed: true)
        settings.beginRecording(.volumeDown)
        staysStopped()
        settings.cancelRecording()
        send(.volumeUp, pressed: true)
        settings.setShortcut(nil, for: .volumeUp)
        staysStopped()
        settings.setShortcut(up, for: .volumeUp)

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            send(.volumeUp, pressed: true)
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            staysStopped()
        }
        send(.volumeDown, pressed: true)
        settings.stop()
        staysStopped()
        settings.start()
        let beforeRestart = actions.count
        send(.volumeDown, pressed: true)
        pump(0.5)
        precondition(actions.count >= beforeRestart + 2)
        send(.volumeDown, pressed: false)
        staysStopped()
        print("PASS: native Carbon press/release, tap/hold, duplicate presses, single window toggle, direction switch, recording/rebinding, sleep/session, stop/restart; no audio writes")
    }
}
