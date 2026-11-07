import CoreAudio
import Foundation

/// Controls the current default output, independent of per-application gain.
enum SystemVolumeController {
    static func adjust(by delta: Double) throws -> Float {
        try adjust(by: delta, backend: CoreAudioVolumeBackend())
    }

    /// The maximum channel scalar represents the output level when no main scalar exists.
    /// The backend overload keeps checks independent of the host's audio hardware.
    static func adjust<B: SystemVolumeBackend>(by delta: Double, backend: B) throws -> Float {
        guard delta.isFinite else { throw SystemVolumeError.invalidDelta }
        let device = try backend.defaultOutputDevice()
        let main = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        let volume = kAudioDevicePropertyVolumeScalar
        let mute = kAudioDevicePropertyMute
        let elements: [AudioObjectPropertyElement]
        if backend.hasProperty(device, volume, main), try backend.isSettable(device, volume, main) {
            elements = [main]
        } else {
            let count = try backend.outputChannelCount(device)
            guard count > 0 else { throw SystemVolumeError.fixedVolume }
            elements = (1...count).map { AudioObjectPropertyElement($0) }
            // Reject incomplete channel control before reading or changing any channel.
            for element in elements {
                guard backend.hasProperty(device, volume, element),
                      try backend.isSettable(device, volume, element) else {
                    throw SystemVolumeError.fixedVolume
                }
            }
        }
        let original = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
        let muteElements: [AudioObjectPropertyElement]
        let channelCount = try backend.outputChannelCount(device)
        let channelMutes = channelCount == 0 ? [] : (1...channelCount).filter { backend.hasProperty(device, mute, $0) }
        muteElements = (backend.hasProperty(device, mute, main) ? [main] : []) + channelMutes
        let originalMutes = try muteElements.map { try backend.isMuted(device, $0) }
        func globallyMuted(_ values: [Bool]) -> Bool {
            let states = Dictionary(uniqueKeysWithValues: zip(muteElements, values))
            if states[main] == true { return true }
            return channelCount > 0 && (1...channelCount).allSatisfy { states[$0] == true }
        }
        let wasMuted = globallyMuted(originalMutes)
        // Volume-down while muted must not expose the remembered (possibly loud) level.
        if wasMuted && delta <= 0 { return 0 }
        if delta == 0 { return original.max() ?? 0 }
        for (index, element) in muteElements.enumerated() where wasMuted && originalMutes[index] {
            guard try backend.isSettable(device, mute, element) else {
                throw SystemVolumeError.cannotUnmute
            }
        }

        let currentLevel = Double(original.max() ?? 0)
        let targetLevel = min(1, max(0, (wasMuted ? 0 : currentLevel) + delta))
        // Scale channels together to retain their relative balance and still allow
        // the entire output to reach zero when one channel is already silent.
        let targets = original.map { value in
            Float(min(1, max(0, currentLevel > 0 ? Double(value) / currentLevel * targetLevel : targetLevel)))
        }

        var attemptedVolumes: [Int] = []
        var attemptedMutes: [Int] = []
        do {
            for index in elements.indices where targets[index] != original[index] {
                attemptedVolumes.append(index)
                try backend.setScalar(device, elements[index], targets[index])
            }
            if wasMuted {
                // Read back before unmuting: a driver may quantize or ignore scalar writes.
                let staged = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
                let ceiling = Float(min(1, max(0, delta)))
                guard staged.allSatisfy({ $0 <= ceiling + 0.0001 }) else {
                    throw SystemVolumeError.cannotSetSafeLevel
                }
                for index in muteElements.indices where originalMutes[index] {
                    attemptedMutes.append(index)
                    try backend.setMuted(device, muteElements[index], false)
                }
            }
            let actual = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
            let muted = try muteElements.map { try backend.isMuted(device, $0) }
            return globallyMuted(muted) ? 0 : (actual.max() ?? 0)
        } catch {
            // Core Audio has no multi-property transaction. Restore mute first so a
            // failed unmute cannot expose the previous louder scalar during rollback.
            var rollbackFailed = false
            for index in attemptedMutes.reversed() {
                do { try backend.setMuted(device, muteElements[index], originalMutes[index]) }
                catch { rollbackFailed = true }
            }
            // If re-muting failed, leave the safer staged level in place.
            if !rollbackFailed {
                for index in attemptedVolumes.reversed() {
                    do { try backend.setScalar(device, elements[index], original[index]) }
                    catch { rollbackFailed = true }
                }
            }
            if rollbackFailed { throw SystemVolumeError.incompleteRestore(error.localizedDescription) }
            throw error
        }
    }

    private static func checkedScalar(_ value: Float) throws -> Float {
        guard value.isFinite, (0...1).contains(value) else {
            throw CoreAudioError.missingValue("有效的输出音量")
        }
        return value
    }
}

enum SystemVolumeError: LocalizedError {
    case fixedVolume
    case cannotUnmute
    case cannotSetSafeLevel
    case invalidDelta
    case incompleteRestore(String)

    var errorDescription: String? {
        switch self {
        case .fixedVolume:
            return "当前输出设备不支持系统音量调节。请使用设备上的音量控制，或在“系统设置 → 声音”中选择其他输出设备。"
        case .cannotUnmute:
            return "当前输出设备无法取消静音。请先使用设备上的控制取消静音，或选择其他输出设备。"
        case .cannotSetSafeLevel:
            return "输出设备未能设置安全的起始音量，已保留静音。请使用设备上的音量控制。"
        case .invalidDelta:
            return "音量调节幅度必须是有限数值。"
        case let .incompleteRestore(reason):
            return "音量调节失败且无法完全恢复原音量。请检查设备音量或在“系统设置 → 声音”中调整。\(reason)"
        }
    }
}

/// Internal injection point; production always uses the Core Audio implementation.
protocol SystemVolumeBackend {
    func defaultOutputDevice() throws -> AudioObjectID
    func outputChannelCount(_ device: AudioObjectID) throws -> UInt32
    func hasProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool
    func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) throws -> Bool
    func scalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Float
    func setScalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Float) throws
    func isMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Bool
    func setMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Bool) throws
}

private struct CoreAudioVolumeBackend: SystemVolumeBackend {
    func defaultOutputDevice() throws -> AudioObjectID {
        try CoreAudioSystem.defaultOutputDevice()
    }

    private func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    func hasProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var property = address(selector, element)
        return AudioObjectHasProperty(device, &property)
    }

    func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) throws -> Bool {
        var property = address(selector, element)
        var writable: DarwinBoolean = false
        try checkStatus(AudioObjectIsPropertySettable(device, &property, &writable), "检查输出音量控制")
        return writable.boolValue
    }

    func outputChannelCount(_ device: AudioObjectID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &property) else { return 0 }
        var size: UInt32 = 0
        try checkStatus(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "读取输出声道配置大小")
        let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        guard size >= headerSize else {
            throw CoreAudioError.missingValue("输出声道配置")
        }
        let allocatedSize = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: allocatedSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try checkStatus(AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage), "读取输出声道配置")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard Int(size) <= allocatedSize, Int(size) >= headerSize,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - headerSize) / MemoryLayout<AudioBuffer>.size else {
            throw CoreAudioError.missingValue("输出声道配置")
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    func scalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Float {
        var value: Float32 = 0
        var property = address(kAudioDevicePropertyVolumeScalar, element)
        var size = UInt32(MemoryLayout<Float32>.size)
        try checkStatus(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "读取输出音量")
        guard size == MemoryLayout<Float32>.size else { throw CoreAudioError.missingValue("输出音量") }
        return value
    }

    func setScalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Float) throws {
        var value = value
        var property = address(kAudioDevicePropertyVolumeScalar, element)
        try checkStatus(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value), "设置输出音量")
    }

    func isMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Bool {
        var value: UInt32 = 0
        var property = address(kAudioDevicePropertyMute, element)
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checkStatus(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "读取输出静音状态")
        guard size == MemoryLayout<UInt32>.size else { throw CoreAudioError.missingValue("输出静音状态") }
        return value != 0
    }

    func setMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Bool) throws {
        var value: UInt32 = value ? 1 : 0
        var property = address(kAudioDevicePropertyMute, element)
        try checkStatus(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), "设置输出静音状态")
    }
}
