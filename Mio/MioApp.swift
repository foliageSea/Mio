import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindowController?
    private let volumeHUD = VolumeHUD()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mio")
            button.target = self
            button.action = #selector(toggleMixer)
        }
        statusItem = item
        popover.behavior = .transient
        popover.animates = false
        let mixerController = NSHostingController(rootView:
            MixerMenuView(onOpenSettings: { [weak self] in self?.showSettings() })
                .environmentObject(MixerStore.shared)
        )
        popover.contentViewController = mixerController
        ShortcutSettings.shared.onAction = { [weak self] action in
            switch action {
            case .toggleWindow: self?.toggleMixer()
            case .volumeUp: self?.adjustGlobalVolume(direction: 1)
            case .volumeDown: self?.adjustGlobalVolume(direction: -1)
            }
        }
        ShortcutSettings.shared.start()

        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Mio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }

    @objc private func showSettings() {
        popover.close()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: controller)
            window.title = "Mio 设置"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 480, height: 376))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMixer() {
        if popover.isShown {
            popover.close()
        } else if let button = statusItem?.button, button.window != nil {
            MixerStore.shared.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func adjustGlobalVolume(direction: Double) {
        do {
            let volume = try SystemVolumeController.adjust(by: direction * ShortcutSettings.shared.volumeStepPercent / 100)
            volumeHUD.show(volume: volume)
        } catch {
            volumeHUD.show(error: error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShortcutSettings.shared.stop()
        MixerStore.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MioApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
