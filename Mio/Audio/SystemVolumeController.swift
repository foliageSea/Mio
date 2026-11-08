import CoreAudio
import Foundation

/// Controls the current default output, independent of per-application gain.
enum SystemVolumeController {
    private static let zeroTolerance = 0.000001

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
        var mutesToDisable: [Int] = []
        if wasMuted {
            var expected = originalMutes
            for (index, element) in muteElements.enumerated() where originalMutes[index] {
                if try backend.isSettable(device, mute, element) {
                    mutesToDisable.append(index)
                    expected[index] = false
                } else if element == main {
                    throw SystemVolumeError.cannotUnmute
                }
            }
            // Preserve locked partial-channel mutes if other channels can become audible.
            guard !globallyMuted(expected) else { throw SystemVolumeError.cannotUnmute }
        }

        let currentLevel = Double(original.max() ?? 0)
        let candidateLevel = min(1, max(0, (wasMuted ? 0 : currentLevel) + delta))
        // Snap only downward arithmetic residue, not intentionally small positive volume.
        let targetLevel = delta < 0 && candidateLevel <= zeroTolerance ? 0 : candidateLevel
        let shouldMute = delta < 0 && targetLevel == 0
        func writableMuteIndices() throws -> [Int] {
            guard !muteElements.isEmpty else { return [] }
            if let index = muteElements.firstIndex(of: main), try backend.isSettable(device, mute, main) {
                return [index]
            }
            // A read-only main mute may still have writable per-channel controls.
            guard channelCount > 0 else { throw SystemVolumeError.cannotMute }
            var indices: [Int] = []
            for channel in 1...channelCount {
                guard let index = muteElements.firstIndex(of: channel) else {
                    throw SystemVolumeError.cannotMute
                }
                if !originalMutes[index] {
                    guard try backend.isSettable(device, mute, channel) else {
                        throw SystemVolumeError.cannotMute
                    }
                    indices.append(index)
                }
            }
            return indices
        }
        let plannedMutes = shouldMute ? try writableMuteIndices() : []
        // Scale channels together to retain their relative balance and still allow
        // the entire output to reach zero when one channel is already silent.
        func balancedTargets(at level: Double) -> [Float] {
            original.map { value in
                Float(min(1, max(0, currentLevel > 0 ? Double(value) / currentLevel * level : level)))
            }
        }
        let targets = balancedTargets(at: targetLevel)
        // Hardware steps may exceed the configured fine step. Permit a low recovery
        // level up to 10%, while still rejecting an ignored write at a loud old level.
        let recoveryCeiling = Float(max(0.1, targetLevel))

        var attemptedVolumes: [Int] = []
        var attemptedMutes: [Int] = []
        do {
            for index in elements.indices where targets[index] != original[index] {
                attemptedVolumes.append(index)
                try backend.setScalar(device, elements[index], targets[index])
            }
            if wasMuted {
                func stagedLevels() throws -> [Float] {
                    var levels = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
                    // Bluetooth drivers may briefly return the previous value after a write.
                    for _ in 0..<3 {
                        if levels.contains(where: { $0 > 0 }) && levels.allSatisfy({ $0 <= recoveryCeiling + 0.0001 }) { break }
                        backend.waitForVolumeUpdate()
                        levels = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
                    }
                    return levels
                }
                var staged = try stagedLevels()
                var requested = targetLevel
                while !staged.contains(where: { $0 > 0 }) {
                    // Find an audible hardware step when a fine software step rounds to zero.
                    let next = min(Double(recoveryCeiling), max(0.005, requested * 2))
                    guard next > requested else { throw SystemVolumeError.cannotSetSafeLevel }
                    requested = next
                    let retryTargets = balancedTargets(at: requested)
                    for index in elements.indices {
                        if !attemptedVolumes.contains(index) { attemptedVolumes.append(index) }
                        try backend.setScalar(device, elements[index], retryTargets[index])
                    }
                    staged = try stagedLevels()
                }
                guard staged.allSatisfy({ $0 <= recoveryCeiling + 0.0001 }) else {
                    throw SystemVolumeError.cannotSetSafeLevel
                }
                for index in mutesToDisable {
                    attemptedMutes.append(index)
                    try backend.setMuted(device, muteElements[index], false)
                }
            }
            let actual = try elements.map { try checkedScalar(backend.scalar(device, $0)) }
            var muted = try muteElements.map { try backend.isMuted(device, $0) }
            let actualLevel = actual.max() ?? 0
            if wasMuted {
                guard !globallyMuted(muted), mutesToDisable.allSatisfy({ !muted[$0] }) else {
                    throw SystemVolumeError.cannotUnmute
                }
                guard actualLevel > 0, actualLevel <= recoveryCeiling + 0.0001 else {
                    throw SystemVolumeError.cannotSetSafeLevel
                }
            }
            if shouldMute || (delta < 0 && actualLevel == 0) {
                // Also cover a driver rounding a positive requested level down to zero.
                let indices = shouldMute ? plannedMutes : try writableMuteIndices()
                for index in indices where !muted[index] {
                    attemptedMutes.append(index)
                    try backend.setMuted(device, muteElements[index], true)
                }
                muted = try muteElements.map { try backend.isMuted(device, $0) }
                if !globallyMuted(muted) {
                    guard muteElements.isEmpty else { throw SystemVolumeError.cannotMute }
                    guard actualLevel == 0 else { throw SystemVolumeError.cannotSetZeroLevel }
                }
            }
            return globallyMuted(muted) ? 0 : actualLevel
        } catch {
            // Core Audio has no multi-property transaction. Restore mute first so a
            // failed unmute cannot expose the previous louder scalar during rollback.
            var rollbackFailed = false
            for index in attemptedMutes.reversed() {
                do { try backend.setMuted(device, muteElements[index], originalMutes[index]) }
                catch { rollbackFailed = true }
            }
            // A successful write may still have been ignored by the device.
            do {
                let restored = try muteElements.map { try backend.isMuted(device, $0) }
                if attemptedMutes.contains(where: { restored[$0] != originalMutes[$0] }) || (wasMuted && !globallyMuted(restored)) {
                    rollbackFailed = true
                }
            } catch { rollbackFailed = true }
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
    case cannotMute
    case cannotSetZeroLevel
    case cannotSetSafeLevel
    case invalidDelta
    case incompleteRestore(String)

    var errorDescription: String? {
        switch self {
        case .fixedVolume:
            return "当前输出设备不支持系统音量调节。请使用设备上的音量控制，或在“系统设置 → 声音”中选择其他输出设备。"
        case .cannotMute:
            return "当前输出设备未能进入静音。请使用设备上的静音控制，或在系统设置中检查输出设备。"
        case .cannotSetZeroLevel:
            return "当前输出设备未能将音量降至零。请使用设备上的静音或音量控制。"
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
    func waitForVolumeUpdate()
}

extension SystemVolumeBackend {
    func waitForVolumeUpdate() {}
}

private struct CoreAudioVolumeBackend: SystemVolumeBackend {
    func waitForVolumeUpdate() { Thread.sleep(forTimeInterval: 0.02) }

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
