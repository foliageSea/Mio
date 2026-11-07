import AppKit
import SwiftUI

struct MixerMenuView: View {
    @EnvironmentObject private var store: MixerStore
    var onOpenSettings: () -> Void = {}
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    @State private var selection = MixerKeyboardSelection()

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionDivider

            if store.processes.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.processes) { process in
                                ProcessVolumeRow(
                                    process: process,
                                    isSelected: selection.selectedID == process.id,
                                    onSelect: { selection.select(process.id) }
                                )
                                .id(process.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    // Give the popover a concrete height even when the list scrolls.
                    .frame(height: processListHeight)
                    .onChange(of: selection.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }

            if let error = store.errorMessage {
                sectionDivider
                errorBanner(error)
            }

            sectionDivider
            footer
        }
        .background {
            MixerKeyboardInput(onArrow: handleArrowKey)
                .frame(width: 0, height: 0)
        }
        .onChange(of: store.processes.map(\.id), initial: true) { _, ids in
            selection.reconcile(ids)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

    }

    private func handleArrowKey(_ keyCode: UInt16) -> Bool {
        let ids = store.processes.map(\.id)
        selection.reconcile(ids)
        guard let id = selection.selectedID else { return false }
        switch keyCode {
        case 126: selection.move(by: -1, in: ids)
        case 125: selection.move(by: 1, in: ids)
        case 123, 124:
            guard let process = store.processes.first(where: { $0.id == id }) else { return false }
            let control = store.control(for: process)
            // Match the disabled slider: arrow keys do not change a muted app.
            guard !control.isMuted else { return true }
            let direction = keyCode == 124 ? 1.0 : -1.0
            store.setVolume(Double(control.volume) + direction * ShortcutSettings.shared.volumeStepPercent / 100, for: process)
        default: return false
        }
        return true
    }

    private var bodyHeightBudget: CGFloat {
        // Reserve the header/footer and a bounded error banner before sizing the list.
        max(0, maximumHeight - (store.errorMessage == nil ? 96 : 180))
    }

    private var processListHeight: CGFloat {
        min(CGFloat(store.processes.count) * 62 + 12, 380, bodyHeightBudget)
    }

    private var header: some View {
        MioGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                Image("MioMenuBar")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22.0 * 178.0 / 326.0)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Mio")

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle()
                        .fill(store.processes.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(store.processes.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .mioGlassBadge(in: Capsule())

                MioIconButton(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .help("刷新应用列表")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46, height: 46)
            .mioGlassBadge(in: Circle())

            Text("暂无音频应用")
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: min(168, max(0, bodyHeightBudget - 32)))
        .padding(16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .help(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            MioIconButton(action: { store.dismissError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var footer: some View {
        MioGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                MioIconButton {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .help("设置")
                .accessibilityLabel("设置")
                Spacer()
                MioIconButton(tint: .red) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .help("退出 Mio")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

/// Receives keys before a focused slider or scroll view can consume the arrows.
/// The monitor is local to this process and scoped to the hosting window.
struct MixerKeyboardInput: NSViewRepresentable {
    let onArrow: (UInt16) -> Bool

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) {
        view.onArrow = onArrow
    }

    static func dismantleNSView(_ view: KeyMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class KeyMonitorView: NSView {
        var onArrow: ((UInt16) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      window.isVisible, window.isKeyWindow, event.window === window,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      (123...126).contains(event.keyCode),
                      self.onArrow?(event.keyCode) == true else { return event }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopMonitoring() }
    }
}

private struct ProcessVolumeRow: View {
    @EnvironmentObject private var store: MixerStore
    @State private var isHovered = false

    let process: AudioProcessInfo
    let isSelected: Bool
    let onSelect: () -> Void

    private var control: SavedControl {
        store.control(for: process)
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: process.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(process.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(control.isMuted ? "静音" : "\(Int(control.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(control.isMuted ? Color.orange : Color.secondary)
                        .frame(width: 42, alignment: .trailing)
                }

                Slider(
                    value: Binding(
                        get: { Double(control.volume) },
                        set: {
                            onSelect()
                            store.setVolume($0, for: process)
                        }
                    ),
                    in: 0 ... 1
                )
                .disabled(control.isMuted)
                .tint(control.isMuted ? .secondary : .accentColor)
            }

            MioIconButton(tint: control.isMuted ? .orange : nil) {
                onSelect()
                store.toggleMute(for: process)
            } label: {
                Image(systemName: control.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(control.isMuted ? Color.orange : Color.primary)
                    .frame(width: 30, height: 30)
            }
            .help(control.isMuted ? "取消静音" : "静音")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.055 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : .clear)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

private struct MioIconButton<Label: View>: View {
    let tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    init(
        tint: Color? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.tint = tint
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(MioIconButtonStyle(tint: tint, isHovered: isHovered))
            .onHover { isHovered = $0 }
    }
}

private struct MioIconButtonStyle: ButtonStyle {
    let tint: Color?
    let isHovered: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let color = tint ?? .primary

        configuration.label
            .foregroundStyle(isHovered ? color : (tint ?? .secondary))
            .background {
                Circle()
                    .fill(color.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.09 : 0.04)))
            }
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MioGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
#else
        content()
#endif
    }
}

private extension View {
    @ViewBuilder
    func mioGlassBadge<S: InsettableShape>(in shape: S) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            legacyGlassBadge(in: shape)
        }
#else
        legacyGlassBadge(in: shape)
#endif
    }

    func legacyGlassBadge<S: InsettableShape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.2))
            }
    }
}
