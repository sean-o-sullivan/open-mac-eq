import CoreAudio
import Foundation

struct AudioDeviceDescriptor: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let modelUID: String?
    let transportType: UInt32
    let isDefaultOutput: Bool
    let isAlive: Bool
    let sampleRate: Double
    let bufferFrameSize: UInt32
    let deviceLatencyFrames: UInt32
    let safetyOffsetFrames: UInt32

    var isAirPodsPro: Bool {
        DeviceClassifier.isAirPodsPro(name: name, modelUID: modelUID)
    }

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        default:
            return "0x\(String(transportType, radix: 16))"
        }
    }

    var bufferDurationMilliseconds: Double? {
        AudioTiming.milliseconds(frames: bufferFrameSize, sampleRate: sampleRate)
    }

    func replacingBufferFrameSize(_ frames: UInt32) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: id,
            uid: uid,
            name: name,
            modelUID: modelUID,
            transportType: transportType,
            isDefaultOutput: isDefaultOutput,
            isAlive: isAlive,
            sampleRate: sampleRate,
            bufferFrameSize: frames,
            deviceLatencyFrames: deviceLatencyFrames,
            safetyOffsetFrames: safetyOffsetFrames
        )
    }
}

enum AudioDeviceCatalog {
    static func outputDevices() throws -> [AudioDeviceDescriptor] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultOutput: AudioObjectID = try CoreAudioProperty.scalar(
            objectID: system,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            initialValue: kAudioObjectUnknown,
            operation: "read default output device"
        )
        let deviceIDs = try CoreAudioProperty.objectIDs(
            objectID: system,
            selector: kAudioHardwarePropertyDevices,
            operation: "enumerate audio devices"
        )

        return deviceIDs.compactMap { deviceID in
            guard hasOutputStreams(deviceID) else { return nil }
            return try? descriptor(deviceID: deviceID, defaultOutput: defaultOutput)
        }
        .sorted { lhs, rhs in
            if lhs.isDefaultOutput != rhs.isDefaultOutput { return lhs.isDefaultOutput }
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultOutputID() throws -> AudioObjectID {
        try CoreAudioProperty.scalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            initialValue: kAudioObjectUnknown,
            operation: "read default output device"
        )
    }

    static func ownProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &outputSize,
                &processObjectID
            )
        }
        try checkOSStatus(status, "translate app PID to Core Audio process")
        guard processObjectID != kAudioObjectUnknown else {
            throw CoreAudioFailure(
                operation: "Core Audio has not registered this app process",
                status: kAudioHardwareUnspecifiedError
            )
        }
        return processObjectID
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func descriptor(
        deviceID: AudioObjectID,
        defaultOutput: AudioObjectID
    ) throws -> AudioDeviceDescriptor {
        let name = try CoreAudioProperty.string(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            operation: "read device name"
        )
        let uid = try CoreAudioProperty.string(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "read device UID"
        )
        let modelUID = try? CoreAudioProperty.string(
            objectID: deviceID,
            selector: kAudioDevicePropertyModelUID,
            operation: "read device model UID"
        )
        let transport: UInt32 = (try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertyTransportType,
            initialValue: UInt32(0),
            operation: "read transport type"
        )) ?? 0
        let alive: UInt32 = (try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            initialValue: UInt32(0),
            operation: "read liveness"
        )) ?? 0
        let actualSampleRate: Float64? = try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertyActualSampleRate,
            initialValue: Float64(0),
            operation: "read actual sample rate"
        )
        let sampleRate: Float64
        if let actualSampleRate, actualSampleRate > 0 {
            sampleRate = actualSampleRate
        } else {
            sampleRate = try CoreAudioProperty.scalar(
                objectID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                initialValue: Float64(0),
                operation: "read nominal sample rate"
            )
        }
        let bufferFrames: UInt32 = (try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            initialValue: UInt32(0),
            operation: "read buffer frame size"
        )) ?? 0
        let latency: UInt32 = (try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertyLatency,
            scope: kAudioDevicePropertyScopeOutput,
            initialValue: UInt32(0),
            operation: "read output latency"
        )) ?? 0
        let safetyOffset: UInt32 = (try? CoreAudioProperty.scalar(
            objectID: deviceID,
            selector: kAudioDevicePropertySafetyOffset,
            scope: kAudioDevicePropertyScopeOutput,
            initialValue: UInt32(0),
            operation: "read output safety offset"
        )) ?? 0

        return AudioDeviceDescriptor(
            id: deviceID,
            uid: uid,
            name: name,
            modelUID: modelUID,
            transportType: transport,
            isDefaultOutput: deviceID == defaultOutput,
            isAlive: alive != 0,
            sampleRate: sampleRate,
            bufferFrameSize: bufferFrames,
            deviceLatencyFrames: latency,
            safetyOffsetFrames: safetyOffset
        )
    }
}

final class AudioDeviceChangeObserver {
    private struct Registration {
        let address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let queue = DispatchQueue(label: "app.openmaceq.openEq.device-changes")
    private var registrations: [Registration] = []

    init(onChange: @escaping () -> Void) throws {
        do {
            try observe(selector: kAudioHardwarePropertyDefaultOutputDevice, onChange: onChange)
            try observe(selector: kAudioHardwarePropertyDevices, onChange: onChange)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
    }

    private func observe(
        selector: AudioObjectPropertySelector,
        onChange: @escaping () -> Void
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        try checkOSStatus(
            AudioObjectAddPropertyListenerBlock(systemObject, &address, queue, listener),
            "observe Core Audio output-device changes"
        )
        registrations.append(Registration(address: address, listener: listener))
    }

    private func invalidate() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                queue,
                registration.listener
            )
        }
        registrations.removeAll()
    }
}
