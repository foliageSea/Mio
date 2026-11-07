import CoreAudio
import Foundation

final class AudioController {
    private var pipelines: [AudioObjectID: AppAudioPipeline] = [:]

    func apply(processID: AudioObjectID, gain: Float) throws {
        if gain >= 0.999 {
            remove(processID: processID)
            return
        }

        let outputDeviceID = try CoreAudioSystem.defaultOutputDevice()
        if let pipeline = pipelines[processID], pipeline.outputDeviceID == outputDeviceID {
            pipeline.setGain(gain)
            return
        }

        remove(processID: processID)
        pipelines[processID] = try AppAudioPipeline(
            processID: processID,
            outputDeviceID: outputDeviceID,
            initialGain: gain
        )
    }

    func remove(processID: AudioObjectID) {
        guard let pipeline = pipelines.removeValue(forKey: processID) else { return }
        pipeline.stop()
    }

    func retainOnly(processIDs: Set<AudioObjectID>) {
        let staleProcessIDs = pipelines.keys.filter { !processIDs.contains($0) }
        for processID in staleProcessIDs {
            remove(processID: processID)
        }
    }

    func shutdown() {
        let currentPipelines = Array(pipelines.values)
        pipelines.removeAll()
        currentPipelines.forEach { $0.stop() }
    }
}
