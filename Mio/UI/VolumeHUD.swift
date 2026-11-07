import AppKit
import SwiftUI

@MainActor
final class VolumeHUD {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(volume: Float) {
        show(VolumeHUDView(volume: volume, error: nil), duration: 1.4)
    }

    func show(error: String) {
        show(VolumeHUDView(volume: nil, error: error), duration: 3)
    }

    private func show(_ view: VolumeHUDView, duration: TimeInterval) {
        dismissTimer?.invalidate()
        let size = NSSize(width: view.error == nil ? 230 : 340, height: view.error == nil ? 80 : 100)
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            self.panel = panel
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        panel.setContentSize(size)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        panel.orderFrontRegardless()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak panel] _ in
            panel?.orderOut(nil)
        }
    }
}

private struct VolumeHUDView: View {
    let volume: Float?
    let error: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: error != nil ? "speaker.badge.exclamationmark" : (volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 22, weight: .medium))
            if let volume {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int((Double(volume) * 100).rounded()))%")
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                    ProgressView(value: Double(volume))
                        .tint(.primary)
                }
            } else if let error {
                Text(error)
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.primary.opacity(0.08))
        }
        .padding(1)
    }
}
