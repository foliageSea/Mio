import AppKit
import Carbon

@main
struct ShortcutChecks {
    static func main() {
        _ = NSApplication.shared
        let name = "MioShortcutChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ShortcutSettings(defaults: defaults)
        assert(settings.shortcut(for: .toggleWindow) == .initial)
        settings.setShortcut(nil)
        settings.start()
        defer { settings.stop() }
        let flags = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let candidate = AppShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: flags, key: "K")
        settings.setShortcut(candidate)
        assert(settings.shortcut(for: .toggleWindow) == candidate && settings.errorMessage == nil)
        assert(ShortcutSettings(defaults: defaults).shortcut(for: .toggleWindow) == candidate)
        assert(candidate.display == "⌃⌥⇧⌘K")
        settings.beginRecording()
        assert(settings.isRecording)
        settings.cancelRecording()
        assert(!settings.isRecording && settings.shortcut(for: .toggleWindow) == candidate)

        let occupied = AppShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: flags, key: "J")
        var external: EventHotKeyRef?
        assert(RegisterEventHotKey(occupied.keyCode, flags, EventHotKeyID(signature: 0x54657374, id: 7), GetApplicationEventTarget(), 0, &external) == noErr)
        settings.setShortcut(occupied)
        assert(settings.shortcut(for: .toggleWindow) == candidate && settings.errorMessage != nil)
        if let external { UnregisterEventHotKey(external) }
        assert(ShortcutSettings(defaults: defaults).shortcut(for: .toggleWindow) == candidate)

        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        settings.beginRecording()
        settings.record(key(0, [], "a"))
        assert(settings.isRecording && settings.errorMessage != nil)
        settings.record(key(UInt16(kVK_Escape), [], ""))
        assert(!settings.isRecording && settings.shortcut(for: .toggleWindow) == candidate)
        settings.beginRecording()
        settings.record(key(UInt16(kVK_ANSI_K), [.command, .control, .option, .shift], "K"))
        assert(!settings.isRecording && settings.shortcut(for: .toggleWindow)?.keyCode == UInt32(kVK_ANSI_K))

        var triggered: [ShortcutAction] = []
        settings.onAction = { triggered.append($0) }
        var event: EventRef?
        assert(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
        var identifier = EventHotKeyID(signature: 0x4D696F48, id: 1)
        assert(SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        assert(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
        ReleaseEvent(event!)
        assert(triggered == [.toggleWindow])

        settings.beginRecording()
        settings.record(key(UInt16(kVK_Delete), [], ""))
        assert(!settings.isRecording && settings.shortcut(for: .toggleWindow) == nil)
        assert(ShortcutSettings(defaults: defaults).shortcut(for: .toggleWindow) == nil)
        settings.beginRecording()
        settings.stop()
        settings.cancelRecording()
        assert(!settings.isRecording)
        settings.setShortcut(candidate)
        settings.start()
        assert(settings.shortcut(for: .toggleWindow) == candidate && settings.errorMessage == nil)
        settings.setShortcut(nil)
        print("PASS: registration, persistence, conflict rollback, recording, cancellation, clearing, callback")
    }
}
