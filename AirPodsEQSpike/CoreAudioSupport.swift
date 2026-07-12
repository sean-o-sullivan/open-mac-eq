import CoreAudio
import Foundation

struct CoreAudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed: \(Self.describe(status)) (\(status))"
    }

    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "OSStatus"
        }
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
    }
}

@inline(__always)
func checkOSStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CoreAudioFailure(operation: operation, status: status)
    }
}

enum CoreAudioProperty {
    static func scalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        initialValue: T,
        operation: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        try checkOSStatus(status, operation)
        return value
    }

    static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        try checkOSStatus(status, operation)
        return value as String
    }

    static func setScalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: T,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var mutableValue = value
        let status = withUnsafePointer(to: &mutableValue) { pointer in
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<T>.size),
                pointer
            )
        }
        try checkOSStatus(status, operation)
    }

    static func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try checkOSStatus(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            "\(operation) size"
        )

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try checkOSStatus(status, operation)
        return values
    }

    static func streamFormat(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> AudioStreamBasicDescription {
        try scalar(
            objectID: objectID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: scope,
            initialValue: AudioStreamBasicDescription(),
            operation: operation
        )
    }
}
