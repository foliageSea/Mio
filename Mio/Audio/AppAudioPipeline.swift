import CoreAudio
import Foundation

final class AppAudioPipeline {
    let processID: AudioObjectID
    let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var gainState: UnsafeMutableRawPointer?
    private var isStarted = false

    init(processID: AudioObjectID, outputDeviceID: AudioObjectID, initialGain: Float) throws {
        self.processID = processID
        self.outputDeviceID = outputDeviceID

        guard let state = AMGainStateCreate(initialGain) else {
            throw CoreAudioError.missingValue("音量状态")
        }
        gainState = state

        do {
            try createAndStart()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func setGain(_ gain: Float) {
        guard let gainState else { return }
        AMGainStateSet(gainState, max(0, min(gain, 1)))
    }

    func stop() {
        if isStarted, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            isStarted = false
        }

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if let gainState {
            AMGainStateDestroy(gainState)
            self.gainState = nil
        }
    }

    private func createAndStart() throws {
        let outputUID = try CoreAudioSystem.deviceUID(outputDeviceID)
        let tapDescription = CATapDescription(
            processes: [processID],
            deviceUID: outputUID,
            stream: 0
        )
        tapDescription.name = "Mio \(processID)"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        try checkStatus(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            "创建应用音频 Tap"
        )

        var format = try CoreAudioSystem.tapFormat(tapID)
        guard AMAudioFormatIsSupported(&format) else {
            throw CoreAudioError.unsupportedFormat(format)
        }

        let aggregateUID = "com.mio.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let outputEntry: [String: Any] = [
            kAudioSubDeviceUIDKey: outputUID,
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mio Private Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [outputEntry],
            kAudioAggregateDeviceTapListKey: [tapEntry],
        ]

        try checkStatus(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            "创建私有聚合音频设备"
        )

        guard let gainState else {
            throw CoreAudioError.missingValue("音量状态")
        }
        let formatCopy = format
        var createdIOProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProc,
            aggregateDeviceID,
            nil
        ) { _, inputData, _, outputData, _ in
            var callbackFormat = formatCopy
            AMProcessAudio(inputData, outputData, gainState, &callbackFormat)
        }
        try checkStatus(status, "创建实时音频回调")
        ioProcID = createdIOProc

        try checkStatus(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            "启动应用音频控制"
        )
        isStarted = true
    }
}
