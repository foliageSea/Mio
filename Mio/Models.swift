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

struct SavedControl: Codable {
    var volume: Float = 1
    var isMuted = false
}
