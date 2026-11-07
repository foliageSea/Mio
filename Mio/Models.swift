import AppKit
import CoreAudio

struct AudioProcessInfo: Identifiable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage

    var persistenceKey: String {
        bundleID.isEmpty ? "pid:\(pid)" : bundleID
    }
}

struct MixerKeyboardSelection {
    private(set) var selectedID: AudioObjectID?

    mutating func reconcile(_ ids: [AudioObjectID]) {
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }

    mutating func select(_ id: AudioObjectID) {
        selectedID = id
    }

    mutating func move(by offset: Int, in ids: [AudioObjectID]) {
        reconcile(ids)
        guard let selectedID, let index = ids.firstIndex(of: selectedID) else { return }
        self.selectedID = ids[min(ids.count - 1, max(0, index + offset))]
    }
}

struct SavedControl: Codable {
    var volume: Float = 1
    var isMuted = false
}
