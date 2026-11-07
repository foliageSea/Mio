import AppKit
import CoreAudio
import Foundation

enum AudioProcessDiscovery {
    static func activeOutputProcesses() throws -> [AudioProcessInfo] {
        let objectIDs = try processObjectIDs()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return objectIDs.compactMap { objectID in
            guard let process = try? makeProcess(objectID),
                  process.pid != ownPID,
                  process.isRunningOutput else {
                return nil
            }
            return process.info
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func processObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            "读取音频进程列表大小"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        try checkStatus(status, "读取音频进程列表")
        return values
    }

    private struct DiscoveredProcess {
        let pid: pid_t
        let isRunningOutput: Bool
        let info: AudioProcessInfo
    }

    private static func makeProcess(_ objectID: AudioObjectID) throws -> DiscoveredProcess {
        let pid: pid_t = try scalarProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyPID,
            operation: "读取音频进程 PID"
        )
        let running: UInt32 = try scalarProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            operation: "读取音频进程状态"
        )
        let bundleID = (try? CoreAudioSystem.retainedStringProperty(
            objectID: objectID,
            selector: kAudioProcessPropertyBundleID,
            operation: "读取音频进程标识"
        )) ?? ""

        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let name = runningApplication?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? "进程 \(pid)"
        let icon = runningApplication?.icon
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 24, height: 24))

        return DiscoveredProcess(
            pid: pid,
            isRunningOutput: running != 0,
            info: AudioProcessInfo(
                id: objectID,
                pid: pid,
                bundleID: bundleID,
                name: name,
                icon: icon
            )
        )
    }

    private static func scalarProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        try checkStatus(status, operation)
        return pointer.move()
    }
}
