import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private let mixerPanel = MixerPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private var settingsWindow: NSWindowController?
    private var mixerController: NSHostingController<AnyView>?
    private var maximumPanelHeight: CGFloat = .greatestFiniteMagnitude
    private let volumeHUD = VolumeHUD()
    private var anchorTrackingTimer: Timer?
    private var localEventMonitor: Any?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "MioMenuBar")
            image?.size = NSSize(width: 22, height: 22.0 * 178.0 / 326.0)
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("Mio")
            button.toolTip = "Mio"
            button.target = self
            button.action = #selector(toggleMixer)
        }
        statusItem = item
        let mixerController = NSHostingController(rootView: makeMixerContent())
        self.mixerController = mixerController
        mixerController.sizingOptions = [.preferredContentSize]
        mixerPanel.contentViewController = mixerController
        mixerPanel.delegate = self
        mixerPanel.level = .popUpMenu
        mixerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        mixerPanel.isOpaque = false
        mixerPanel.backgroundColor = .clear
        mixerPanel.hasShadow = true
        mixerPanel.isReleasedWhenClosed = false
        mixerPanel.onDismiss = { [weak self] in self?.closeMixer() }
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

    private func makeMixerContent() -> AnyView {
        AnyView(
            MixerMenuView(onOpenSettings: { [weak self] in self?.showSettings() }, maximumHeight: maximumPanelHeight)
                .environmentObject(MixerStore.shared)
        )
    }

    @objc private func showSettings() {
        closeMixer()
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
        if mixerPanel.isVisible {
            closeMixer()
            return
        }
        MixerStore.shared.refresh()
        guard positionMixerPanel() else { return }
        NSApp.activate(ignoringOtherApps: true)
        mixerPanel.makeKeyAndOrderFront(nil)
        statusItem?.button?.state = .on
        startPanelMonitoring()
        // Activation may move the status item to another display's menu bar.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mixerPanel.isVisible else { return }
            self.positionMixerPanel()
        }
    }

    @discardableResult
    private func positionMixerPanel() -> Bool {
        guard let button = statusItem?.button, let anchorWindow = button.window,
              anchorWindow.isVisible, let screen = anchorWindow.screen,
              let contentView = mixerPanel.contentViewController?.view else { return false }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor.intersects(screen.frame) else { return false }
        let bounds = screen.visibleFrame
        let top = min(anchor.minY, bounds.maxY)
        let availableHeight = max(0, top - bounds.minY)
        if abs(maximumPanelHeight - availableHeight) > 0.5 {
            maximumPanelHeight = availableHeight
            mixerController?.rootView = makeMixerContent()
            contentView.layoutSubtreeIfNeeded()
        }
        let size = contentView.fittingSize
        guard size.width > 0, size.height > 0, availableHeight > 0 else { return false }
        let height = min(size.height, availableHeight)
        let x = max(bounds.minX + 4, min(anchor.midX - size.width / 2, bounds.maxX - size.width - 4))
        let frame = NSRect(x: x, y: top - height, width: size.width, height: height)
        if mixerPanel.frame != frame { mixerPanel.setFrame(frame, display: true) }
        return true
    }

    private func startPanelMonitoring() {
        stopPanelMonitoring()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mixerPanel.isVisible else { return }
                if !self.positionMixerPanel() { self.closeMixer() }
            }
        }
        anchorTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.mixerPanel.isVisible else { return event }
            if event.type == .keyDown {
                if event.window === self.mixerPanel && event.keyCode == 53 {
                    self.closeMixer()
                    return nil
                }
            } else if event.window !== self.mixerPanel && event.window !== self.statusItem?.button?.window {
                self.closeMixer()
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeMixer()
        }
    }

    private func stopPanelMonitoring() {
        anchorTrackingTimer?.invalidate()
        anchorTrackingTimer = nil
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        localEventMonitor = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func closeMixer() {
        stopPanelMonitoring()
        mixerPanel.orderOut(nil)
        statusItem?.button?.state = .off
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === mixerPanel { closeMixer() }
    }

    func applicationDidResignActive(_ notification: Notification) { closeMixer() }

    private func adjustGlobalVolume(direction: Double) {
        do {
            let volume = try SystemVolumeController.adjust(by: direction * ShortcutSettings.shared.volumeStepPercent / 100)
            volumeHUD.show(volume: volume)
        } catch {
            volumeHUD.show(error: error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeMixer()
        ShortcutSettings.shared.stop()
        MixerStore.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class MixerPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
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
