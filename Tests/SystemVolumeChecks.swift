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

        let zero = MockVolumeBackend(values: [0: 0.01], mutes: [0: false])
        near(try adjust(zero, -0.01), 0)
        precondition(zero.values[0] == 0 && zero.mutes[0] == true)
        precondition(zero.events == ["volume:0", "mute:0:true"])
        near(try adjust(zero, 0.01), 0.01)
        precondition(zero.mutes[0] == false)
        precondition(Array(zero.events.suffix(2)) == ["volume:0", "mute:0:false"])

        let residue = MockVolumeBackend(values: [0: 0.1], mutes: [0: false])
        for _ in 0..<10 { _ = try adjust(residue, -0.01) }
        precondition(residue.values[0] == 0 && residue.mutes[0] == true)
        let writesAtZero = residue.events.count
        near(try adjust(residue, -0.01), 0)
        precondition(residue.events.count == writesAtZero)
        let alreadyZero = MockVolumeBackend(values: [0: 0], mutes: [0: false])
        near(try adjust(alreadyZero, -0.01), 0)
        precondition(alreadyZero.events == ["mute:0:true"])
        let subPercent = MockVolumeBackend(values: [0: 0.014], mutes: [0: false])
        near(try adjust(subPercent, -0.01), 0.004)
        precondition(subPercent.mutes[0] == false)

        let perChannelZero = MockVolumeBackend(values: [1: 0.003, 2: 0.01], mutes: [1: false, 2: false])
        near(try adjust(perChannelZero, -0.01), 0)
        precondition(perChannelZero.values.values.allSatisfy { $0 == 0 })
        precondition(perChannelZero.mutes.values.allSatisfy { $0 })
        let masterPreferred = MockVolumeBackend(values: [0: 0.01], mutes: [0: false, 1: false, 2: false])
        near(try adjust(masterPreferred, -0.01), 0)
        precondition(masterPreferred.mutes[0] == true && masterPreferred.mutes[1] == false)
        let channelFallback = MockVolumeBackend(values: [0: 0.01], mutes: [0: false, 1: false, 2: false])
        channelFallback.readOnlyMutes = [0]
        near(try adjust(channelFallback, -0.01), 0)
        precondition(channelFallback.mutes[0] == false && channelFallback.mutes[1] == true && channelFallback.mutes[2] == true)
        let lockedZero = MockVolumeBackend(values: [0: 0.01], mutes: [0: false])
        lockedZero.readOnlyMutes = [0]
        fails(lockedZero, -0.01)
        precondition(lockedZero.events.isEmpty)
        let incompleteMute = MockVolumeBackend(values: [0: 0.01], mutes: [1: false])
        fails(incompleteMute, -0.01)
        precondition(incompleteMute.events.isEmpty)
        let failedMute = MockVolumeBackend(values: [0: 0.01], mutes: [0: false])
        failedMute.failMuteOnce = true
        fails(failedMute, -0.01)
        near(failedMute.values[0]!, 0.01)
        precondition(failedMute.mutes[0] == false)
        let ignoredMute = MockVolumeBackend(values: [0: 0.01], mutes: [0: false])
        ignoredMute.ignoreMuteWrites = true
        fails(ignoredMute, -0.01)
        near(ignoredMute.values[0]!, 0.01)
        let ignoredZero = MockVolumeBackend(values: [0: 0.01])
        ignoredZero.ignoreVolumeWrites = true
        fails(ignoredZero, -0.01)
        near(ignoredZero.values[0]!, 0.01)
        let muteOnly = MockVolumeBackend(values: [0: 0.01], mutes: [0: false])
        muteOnly.ignoreVolumeWrites = true
        near(try adjust(muteOnly, -0.01), 0)
        precondition(muteOnly.mutes[0] == true)

        let quantizedZero = MockVolumeBackend(values: [0: 0.014], mutes: [0: false])
        quantizedZero.quantum = 0.1
        near(try adjust(quantizedZero, -0.01), 0)
        precondition(quantizedZero.mutes[0] == true)
        let lockedPartial = MockVolumeBackend(values: [0: 0.01], mutes: [1: true, 2: false])
        lockedPartial.readOnlyMutes = [1]
        near(try adjust(lockedPartial, -0.01), 0)
        precondition(lockedPartial.mutes[1] == true && lockedPartial.mutes[2] == true)
        near(try adjust(lockedPartial, 0.01), 0.01)
        precondition(lockedPartial.mutes[1] == true && lockedPartial.mutes[2] == false)
        let ignoredUnmute = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        ignoredUnmute.ignoreMuteWrites = true
        fails(ignoredUnmute, 0.01)
        precondition(ignoredUnmute.mutes[0] == true)
        near(ignoredUnmute.values[0]!, 0.9)
        let ignoredRestore = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        ignoredRestore.failUnmuteOnce = true
        ignoredRestore.ignoreRemute = true
        do {
            _ = try adjust(ignoredRestore, 0.01)
            preconditionFailure("Expected ignored rollback error")
        } catch SystemVolumeError.incompleteRestore {}
        near(ignoredRestore.values[0]!, 0.01)
        precondition(ignoredRestore.mutes[0] == false)
        let zeroWake = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        zeroWake.quantum = 0.1
        near(try adjust(zeroWake, 0.01), 0.1)
        precondition(zeroWake.mutes[0] == false)

        let hardwareStep = MockVolumeBackend(values: [0: 0], mutes: [0: true])
        hardwareStep.quantum = 1.0 / 64
        near(try adjust(hardwareStep, 0.01), 1.0 / 64)
        precondition(hardwareStep.mutes[0] == false)
        let coarseStep = MockVolumeBackend(values: [0: 0], mutes: [0: true])
        coarseStep.quantum = 1.0 / 16
        near(try adjust(coarseStep, 0.005), 1.0 / 16)
        precondition(coarseStep.mutes[0] == false)
        let delayed = MockVolumeBackend(values: [0: 0], mutes: [0: true])
        delayed.staleReadsAfterWrite = 2
        near(try adjust(delayed, 0.01), 0.01)
        precondition(delayed.mutes[0] == false && delayed.settleWaits > 0)
        precondition(delayed.events == ["volume:0", "mute:0:false"])
        let delayedLoud = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        delayedLoud.staleReadsAfterWrite = 2
        near(try adjust(delayedLoud, 0.01), 0.01)
        precondition(delayedLoud.mutes[0] == false)
        let ignoredZeroRecovery = MockVolumeBackend(values: [0: 0], mutes: [0: true])
        ignoredZeroRecovery.ignoreVolumeWrites = true
        fails(ignoredZeroRecovery, 0.005)
        precondition(ignoredZeroRecovery.mutes[0] == true && ignoredZeroRecovery.events.count < 20)
        let excessiveStep = MockVolumeBackend(values: [0: 0.75], mutes: [0: true])
        excessiveStep.quantum = 0.25
        fails(excessiveStep, 0.01)
        precondition(excessiveStep.mutes[0] == true)
        near(excessiveStep.values[0]!, 0.75)
        let resetOnUnmute = MockVolumeBackend(values: [0: 0.9], mutes: [0: true])
        resetOnUnmute.resetLevelOnUnmute = 0.8
        fails(resetOnUnmute, 0.01)
        precondition(resetOnUnmute.mutes[0] == true)

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
    var failMuteOnce = false
    var ignoreMuteWrites = false
    var failUnmuteOnce = false
    var failRemute = false
    var ignoreRemute = false
    var failReadAfterWrite = false
    var ignoreVolumeWrites = false
    var quantum: Float?
    var staleReadsAfterWrite = 0
    var staleValues: [UInt32: (Float, Int)] = [:]
    var settleWaits = 0
    var resetLevelOnUnmute: Float?
    func waitForVolumeUpdate() { settleWaits += 1 }
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
        if let (value, remaining) = staleValues[element], remaining > 0 {
            staleValues[element] = (value, remaining - 1)
            return value
        }
        return values[element]!
    }
    func setScalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement, _ value: Float) throws {
        events.append("volume:\(element)")
        if staleReadsAfterWrite > 0 { staleValues[element] = (values[element]!, staleReadsAfterWrite) }
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
        if ignoreMuteWrites || (value && ignoreRemute) { return }
        mutes[element] = value
        if !value, let level = resetLevelOnUnmute {
            for channel in values.keys { values[channel] = level }
        }
        if value && failMuteOnce {
            failMuteOnce = false
            throw CoreAudioError.missingValue("mock mute")
        }
        if !value && failUnmuteOnce {
            failUnmuteOnce = false
            throw CoreAudioError.missingValue("mock unmute")
        }
    }
}
