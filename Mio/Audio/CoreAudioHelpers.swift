import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case operation(String, OSStatus)
    case missingValue(String)
    case unsupportedFormat(AudioStreamBasicDescription)

    var errorDescription: String? {
        switch self {
        case let .operation(operation, status):
            return "\(operation)失败（\(statusDescription(status))）"
        case let .missingValue(name):
            return "无法读取\(name)"
        case let .unsupportedFormat(format):
            return "暂不支持该音频格式：\(format.mBitsPerChannel)-bit / \(format.mFormatID.fourCC)"
        }
    }
}

func checkStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError.operation(operation, status)
    }
}

func statusDescription(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]

    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
       let code = String(bytes: bytes, encoding: .ascii) {
        return "\(code), \(status)"
    }
    return "OSStatus \(status)"
}

extension UInt32 {
    var fourCC: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(self)
    }
}

enum CoreAudioSystem {
    static func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        try checkStatus(status, "读取默认输出设备")
        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.missingValue("默认输出设备")
        }
        return deviceID
    }

    static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try retainedStringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "读取输出设备标识"
        )
    }

    static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        try checkStatus(status, "读取 Tap 音频格式")
        return format
    }

    static func retainedStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        try checkStatus(status, operation)
        guard let value else {
            throw CoreAudioError.missingValue(operation)
        }
        return value.takeRetainedValue() as String
    }
}
