import CoreAudio
import Foundation

/// Compile with CoreAudioHelpers.swift and SystemVolumeController.swift; all I/O is mocked.
@main
struct SystemVolumeChecks {
    static func main() throws {
        func near(_ actual: Float, _ expected: Float) {
            precondition(abs(actual - expected) < 0.00001, "Expected \(expected), got \(actual)")
        }
        func adjust(_ mock: MockVolumeBackend, _ delta: Double) throws -> Float {
            try SystemVolumeController.adjust(by: delta, backend: mock)
        }
        func fails(_ mock: MockVolumeBackend, _ delta: Double) {
            do { _ = try adjust(mock, delta); preconditionFailure("Expected failure") }
            catch {}
        }

        let main = MockVolumeBackend(values: [0: 0.5])
        near(try adjust(main, 0.01), 0.51)
        near(try adjust(main, 5), 1)
        near(try adjust(main, -5), 0)
        precondition(main.defaultReads == 3)

        let balanced = MockVolumeBackend(values: [1: 0.2, 2: 0.8])
        near(try adjust(balanced, 0.4), 1)
        near(balanced.values[1]!, 0.25)
        near(try adjust(balanced, -0.9), 0.1)
        near(balanced.values[1]!, 0.025)
        near(try adjust(balanced, -0.2), 0)
        let writesAtLimit = balanced.events.count
        near(try adjust(balanced, -0.01), 0)
        precondition(balanced.events.count == writesAtLimit)

        let fallback = MockVolumeBackend(values: [0: 0.9, 1: 0.3, 2: 0.5])
        fallback.readOnlyVolumes = [0]
        near(try adjust(fallback, 0.01), 0.51)
        near(fallback.values[0]!, 0.9)
        near(fallback.values[1]!, 0.306)

        let silentChannel = MockVolumeBackend(values: [1: 0, 2: 0.5])
        near(try adjust(silentChannel, -0.01), 0.49)
        near(silentChannel.values[1]!, 0)
        let partialMute = MockVolumeBackend(values: [0: 0.5], mutes: [1: true, 2: false])
        near(try adjust(partialMute, -0.01), 0.49)
        precondition(partialMute.mutes[1] == true && partialMute.mutes[2] == false)

        let fixed = MockVolumeBackend(values: [0: 0.5])
        fixed.readOnlyVolumes = [0]
        fails(fixed, 0.01)
        precondition(fixed.events.isEmpty)
        precondition(SystemVolumeError.fixedVolume.localizedDescription.contains("系统设置"))
        let incomplete = MockVolumeBackend(values: [1: 0.2, 2: 0.6])
        incomplete.readOnlyVolumes = [2]
        fails(incomplete, 0.01)
        precondition(incomplete.events.isEmpty)

        let unreadable = MockVolumeBackend(values: [1: 0.2, 2: 0.6])
        unreadable.failedRead = 2
        fails(unreadable, 0.01)
        precondition(unreadable.events.isEmpty)
        let badScalar = MockVolumeBackend(values: [0: .nan])
        fails(badScalar, 0.01)
        precondition(badScalar.events.isEmpty)
        let invalidDelta = MockVolumeBackend(values: [0: 0.5])
        fails(invalidDelta, .nan)
        fails(invalidDelta, .infinity)
        precondition(invalidDelta.defaultReads == 0)

        let muted = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        near(try adjust(muted, -0.01), 0)
        near(try adjust(muted, 0), 0)
        precondition(muted.events.isEmpty && muted.mutes[0] == true)
        near(try adjust(muted, 0.01), 0.01)
        precondition(muted.events == ["volume:0", "mute:0:false"])
        precondition(muted.mutes[0] == false)
        let channelMute = MockVolumeBackend(values: [0: 0.8], mutes: [1: true, 2: true])
        near(try adjust(channelMute, 0.01), 0.01)
        precondition(channelMute.mutes.values.allSatisfy { !$0 })
        let bothMutes = MockVolumeBackend(values: [0: 0.8], mutes: [0: false, 1: true, 2: true])
        near(try adjust(bothMutes, 0.01), 0.01)
        precondition(bothMutes.mutes.values.allSatisfy { !$0 })
        let mutedChannels = MockVolumeBackend(values: [1: 0.6, 2: 0.9], mutes: [0: true])
        near(try adjust(mutedChannels, 0.01), 0.01)
        near(mutedChannels.values[1]!, 0.01 * 2 / 3)
        near(mutedChannels.values[2]!, 0.01)
        precondition(mutedChannels.events == ["volume:1", "volume:2", "mute:0:false"])
        let lockedMute = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        lockedMute.readOnlyMutes = [0]
        fails(lockedMute, 0.01)
        precondition(lockedMute.events.isEmpty)

        let failedWrite = MockVolumeBackend(values: [1: 0.2, 2: 0.6])
        failedWrite.failVolumeWriteOnce = 2
        fails(failedWrite, 0.01)
        near(failedWrite.values[1]!, 0.2)
        near(failedWrite.values[2]!, 0.6)
        precondition(failedWrite.events == ["volume:1", "volume:2", "volume:2", "volume:1"])
        let failedUnmute = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        failedUnmute.failUnmuteOnce = true
        fails(failedUnmute, 0.01)
        precondition(failedUnmute.mutes[0] == true)
        near(failedUnmute.values[0]!, 0.9)
        precondition(failedUnmute.events == ["volume:0", "mute:0:false", "mute:0:true", "volume:0"])

        let failedRestore = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        failedRestore.failUnmuteOnce = true
        failedRestore.failRemute = true
        do {
            _ = try adjust(failedRestore, 0.01)
            preconditionFailure("Expected rollback error")
        } catch SystemVolumeError.incompleteRestore {}
        near(failedRestore.values[0]!, 0.01)
        precondition(failedRestore.events == ["volume:0", "mute:0:false", "mute:0:true"])

        let readbackFailure = MockVolumeBackend(values: [0: 0.5])
        readbackFailure.failReadAfterWrite = true
        fails(readbackFailure, 0.01)
        near(readbackFailure.values[0]!, 0.5)

        let quantized = MockVolumeBackend(values: [0: 0.5])
        quantized.quantum = 0.1
        near(try adjust(quantized, 0.06), 0.6)
        let ignored = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        ignored.ignoreVolumeWrites = true
        fails(ignored, 0.01)
        precondition(ignored.mutes[0] == true && !ignored.events.contains("mute:0:false"))
        let noOp = MockVolumeBackend(values: [0: 0.6])
        near(try adjust(noOp, 0), 0.6)
        precondition(noOp.events.isEmpty)
        print("PASS: main/channel scalar, clamp/balance, preflight, mute, readback, rollback, invalid input; mock I/O only")
    }
}

private final class MockVolumeBackend: SystemVolumeBackend {
    var values: [UInt32: Float]
    var mutes: [UInt32: Bool]
    var readOnlyVolumes: Set<UInt32> = []
    var readOnlyMutes: Set<UInt32> = []
    var failedRead: UInt32?
    var failVolumeWriteOnce: UInt32?
    var failUnmuteOnce = false
    var failRemute = false
    var failReadAfterWrite = false
    var ignoreVolumeWrites = false
    var quantum: Float?
    var defaultReads = 0
    var events: [String] = []

    init(values: [UInt32: Float], mutes: [UInt32: Bool] = [:]) {
        self.values = values
        self.mutes = mutes
    }
    func defaultOutputDevice() throws -> AudioObjectID {
        defaultReads += 1
        return 123
    }
    func outputChannelCount(_ device: AudioObjectID) throws -> UInt32 { 2 }
    func hasProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        selector == kAudioDevicePropertyMute ? mutes[element] != nil : values[element] != nil
    }
    func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) throws -> Bool {
        selector == kAudioDevicePropertyMute ? !readOnlyMutes.contains(element) : !readOnlyVolumes.contains(element)
    }
    func scalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Float {
        if failReadAfterWrite && !events.isEmpty {
            failReadAfterWrite = false
            throw CoreAudioError.missingValue("mock readback")
        }
        if failedRead == element { throw CoreAudioError.missingValue("mock read") }
        return values[element]!
    }
    func setScalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Float) throws {
        events.append("volume:\(element)")
        if !ignoreVolumeWrites {
            values[element] = quantum.map { (value / $0).rounded() * $0 } ?? value
        }
        // Simulate a driver that changes state before returning an error.
        if failVolumeWriteOnce == element {
            failVolumeWriteOnce = nil
            throw CoreAudioError.missingValue("mock write")
        }
    }
    func isMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) throws -> Bool { mutes[element]! }
    func setMuted(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Bool) throws {
        events.append("mute:\(element):\(value)")
        if value && failRemute { throw CoreAudioError.missingValue("mock restore mute") }
        mutes[element] = value
        if !value && failUnmuteOnce {
            failUnmuteOnce = false
            throw CoreAudioError.missingValue("mock unmute")
        }
    }
}
