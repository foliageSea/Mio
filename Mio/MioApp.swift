import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindowController?
    private let volumeHUD = VolumeHUD()
    private var anchorTrackingTimer: Timer?
    private var lastAnchorRect = NSRect.zero
    private var lastPopoverSize = NSSize.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mio")
            button.target = self
            button.action = #selector(toggleMixer)
        }
        statusItem = item
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        let mixerController = NSHostingController(rootView:
            MixerMenuView(onOpenSettings: { [weak self] in self?.showSettings() })
                .environmentObject(MixerStore.shared)
        )
        mixerController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = mixerController
        popover.contentSize = mixerController.view.fittingSize
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
            if let contentView = popover.contentViewController?.view {
                popover.contentSize = contentView.fittingSize
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Activation can move the status item to another menu bar after show().
            DispatchQueue.main.async { [weak self] in
                self?.synchronizePopoverPosition(force: true)
            }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        anchorTrackingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizePopoverPosition() }
        }
        anchorTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func popoverDidClose(_ notification: Notification) {
        anchorTrackingTimer?.invalidate()
        anchorTrackingTimer = nil
        lastAnchorRect = .zero
        lastPopoverSize = .zero
    }

    private func synchronizePopoverPosition(force: Bool = false) {
        guard popover.isShown, let button = statusItem?.button,
              let anchorWindow = button.window, anchorWindow.isVisible,
              let screen = anchorWindow.screen,
              let window = popover.contentViewController?.view.window else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor.intersects(screen.frame) else { return }
        let contentSize = popover.contentViewController!.view.fittingSize
        let sizeChanged = contentSize != popover.contentSize
        if sizeChanged && contentSize.width > 0 && contentSize.height > 0 {
            popover.contentSize = contentSize
        }
        let gap = anchor.minY - window.frame.maxY
        guard force || sizeChanged || anchor != lastAnchorRect || window.frame.size != lastPopoverSize || gap > 24 || gap < -4 else { return }

        // Reattach to the current view, which AppKit may replace during activation
        // or a display change. Resizing the SwiftUI content also needs a new anchor.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let frame = window.frame
        let updatedGap = anchor.minY - frame.maxY
        let y = updatedGap > 24 || updatedGap < -4 ? anchor.minY - frame.height - 2 : frame.minY
        // Preserve AppKit’s horizontal origin: it accounts for the chevron and
        // screen-edge clamping. Centering the outer window would offset the arrow.
        if abs(frame.minY - y) > 2 {
            window.setFrameOrigin(NSPoint(x: frame.minX, y: y))
        }
        lastAnchorRect = anchor
        lastPopoverSize = window.frame.size
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
        anchorTrackingTimer?.invalidate()
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
