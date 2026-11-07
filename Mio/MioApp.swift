import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MixerStore.shared.shutdown()
    }
}

@main
struct MioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MixerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MixerMenuView()
                .environmentObject(store)
        } label: {
            Label("Mio", systemImage: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)
    }
}
