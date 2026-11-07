import Combine
import CoreAudio
import Foundation

@MainActor
final class MixerStore: ObservableObject {
    static let shared = MixerStore()

    @Published private(set) var processes: [AudioProcessInfo] = []
    @Published private(set) var controls: [String: SavedControl] = [:]
    @Published var errorMessage: String?

    private let controller = AudioController()
    private var refreshTimer: Timer?
    private let defaultsKey = "savedControls"

    private init() {
        loadControls()
        refresh()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(handleRefreshTimer),
            userInfo: nil,
            repeats: true
        )
    }

    func control(for process: AudioProcessInfo) -> SavedControl {
        controls[process.persistenceKey] ?? SavedControl()
    }

    func setVolume(_ volume: Double, for process: AudioProcessInfo) {
        var control = control(for: process)
        control.volume = Float(max(0, min(volume, 1)))
        if control.volume > 0 {
            control.isMuted = false
        }
        controls[process.persistenceKey] = control
        apply(control, to: process)
        saveControls()
    }

    func toggleMute(for process: AudioProcessInfo) {
        var control = control(for: process)
        control.isMuted.toggle()
        controls[process.persistenceKey] = control
        apply(control, to: process)
        saveControls()
    }

    func refresh() {
        do {
            let discovered = try AudioProcessDiscovery.activeOutputProcesses()
            processes = discovered
            controller.retainOnly(processIDs: Set(discovered.map(\.id)))

            for process in discovered {
                let saved = control(for: process)
                if saved.isMuted || saved.volume < 0.999 {
                    apply(saved, to: process)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        controller.shutdown()
    }

    @objc private func handleRefreshTimer() {
        refresh()
    }

    private func apply(_ control: SavedControl, to process: AudioProcessInfo) {
        let gain: Float = control.isMuted ? 0 : control.volume
        do {
            try controller.apply(processID: process.id, gain: gain)
            errorMessage = nil
        } catch {
            errorMessage = "\(process.name)：\(error.localizedDescription)"
        }
    }

    private func loadControls() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([String: SavedControl].self, from: data) else {
            return
        }
        controls = saved
    }

    private func saveControls() {
        guard let data = try? JSONEncoder().encode(controls) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
