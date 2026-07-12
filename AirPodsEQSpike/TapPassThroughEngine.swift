import CoreAudio
import Foundation

struct PassThroughSnapshot: Equatable {
    let callbackCount: UInt64
    let frameCount: UInt64
    let formatMismatchCount: UInt64
    let dspConfigurationApplyCount: UInt64
    let nonFiniteOutputCount: UInt64
    let processorOverloadCount: UInt64
    let timestampDeltaMilliseconds: Double
    let lastProcessingMilliseconds: Double
    let maximumProcessingMilliseconds: Double
    let inputBufferCount: UInt32
    let outputBufferCount: UInt32
    let lastFrameCount: UInt32
    let activeBandCount: UInt32
    let crossfadeFramesRemaining: UInt32

    static let zero = PassThroughSnapshot(
        callbackCount: 0,
        frameCount: 0,
        formatMismatchCount: 0,
        dspConfigurationApplyCount: 0,
        nonFiniteOutputCount: 0,
        processorOverloadCount: 0,
        timestampDeltaMilliseconds: 0,
        lastProcessingMilliseconds: 0,
        maximumProcessingMilliseconds: 0,
        inputBufferCount: 0,
        outputBufferCount: 0,
        lastFrameCount: 0,
        activeBandCount: 0,
        crossfadeFramesRemaining: 0
    )
}

struct PassThroughConfiguration {
    let device: AudioDeviceDescriptor
    let requestedBufferFrameSize: UInt32
    let aggregateBufferFrameSize: UInt32
    let tapFormat: AudioStreamBasicDescription
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
    let aggregateID: AudioObjectID

    var diagnosticLines: [String] {
        [
            "Transport: \(device.transportName)",
            "Device rate/buffer: \(Self.rate(device.sampleRate)) Hz / \(device.bufferFrameSize) frames",
            "Device buffer duration: \(device.bufferDurationMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unknown")",
            "Requested/aggregate buffer: \(requestedBufferFrameSize) / \(aggregateBufferFrameSize) frames",
            "Reported device latency/safety: \(device.deviceLatencyFrames) / \(device.safetyOffsetFrames) frames",
            "Tap format: \(Self.describe(tapFormat))",
            "Aggregate input: \(Self.describe(inputFormat))",
            "Aggregate output: \(Self.describe(outputFormat))",
            "Private aggregate object ID: \(aggregateID)",
        ]
    }

    private static func rate(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        "\(rate(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit, \(format.mBytesPerFrame) B/frame, flags 0x\(String(format.mFormatFlags, radix: 16))"
    }
}

final class TapPassThroughEngine {
    private static let lowLatencyBufferFrameSize: UInt32 = 128

    private(set) var configuration: PassThroughConfiguration?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isDeviceStarted = false
    private var bufferRestore: (deviceID: AudioObjectID, frameSize: UInt32)?
    private let realtimeStats: OpaquePointer
    private let realtimeDSP: OpaquePointer
    private let overloadQueue = DispatchQueue(label: "app.openmaceq.openEq.overload")
    private var overloadListener: AudioObjectPropertyListenerBlock?

    init?() {
        guard let stats = EQRealtimeStatsCreate() else { return nil }
        guard let dsp = EQRealtimeDSPCreate() else {
            EQRealtimeStatsDestroy(stats)
            return nil
        }
        realtimeStats = stats
        realtimeDSP = dsp
    }

    deinit {
        stop()
        EQRealtimeDSPDestroy(realtimeDSP)
        EQRealtimeStatsDestroy(realtimeStats)
    }

    var isRunning: Bool {
        isDeviceStarted
    }

    func start(device: AudioDeviceDescriptor) throws -> PassThroughConfiguration {
        stop()
        EQRealtimeDSPReset(realtimeDSP)
        EQRealtimeStatsReset(realtimeStats)

        guard device.isDefaultOutput else {
            throw SpikeError("Select this device as the macOS default output first.")
        }
        guard device.isAlive else {
            throw SpikeError("Selected output device is not alive.")
        }

        do {
            bufferRestore = (device.id, device.bufferFrameSize)
            try CoreAudioProperty.setScalar(
                objectID: device.id,
                selector: kAudioDevicePropertyBufferFrameSize,
                value: Self.lowLatencyBufferFrameSize,
                operation: "request low-latency output-device buffer"
            )

            let processID = try AudioDeviceCatalog.ownProcessObjectID()
            let tapDescription = CATapDescription(
                excludingProcesses: [processID],
                deviceUID: device.uid,
                stream: 0
            )
            tapDescription.name = "openEq device tap"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .mutedWhenTapped

            try checkOSStatus(
                AudioHardwareCreateProcessTap(tapDescription, &tapID),
                "create device-specific process tap"
            )

            let tapUID = try CoreAudioProperty.string(
                objectID: tapID,
                selector: kAudioTapPropertyUID,
                operation: "read tap UID"
            )
            let tapFormat: AudioStreamBasicDescription = try CoreAudioProperty.scalar(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                initialValue: AudioStreamBasicDescription(),
                operation: "read tap format"
            )

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "openEq Private Aggregate",
                kAudioAggregateDeviceUIDKey: "app.openmaceq.openEq.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: device.uid,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: device.uid],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapUID],
                ],
            ]
            try checkOSStatus(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                "create private tap/output aggregate"
            )

            try CoreAudioProperty.setScalar(
                objectID: aggregateID,
                selector: kAudioDevicePropertyBufferFrameSize,
                value: Self.lowLatencyBufferFrameSize,
                operation: "request low-latency aggregate buffer"
            )
            try CoreAudioProperty.setScalar(
                objectID: device.id,
                selector: kAudioDevicePropertyBufferFrameSize,
                value: Self.lowLatencyBufferFrameSize,
                operation: "confirm low-latency output-device buffer"
            )

            let physicalBufferFrames: UInt32 = try CoreAudioProperty.scalar(
                objectID: device.id,
                selector: kAudioDevicePropertyBufferFrameSize,
                initialValue: UInt32(0),
                operation: "verify output-device buffer size"
            )
            let aggregateBufferFrames: UInt32 = try CoreAudioProperty.scalar(
                objectID: aggregateID,
                selector: kAudioDevicePropertyBufferFrameSize,
                initialValue: UInt32(0),
                operation: "verify aggregate buffer size"
            )

            let inputFormat = try CoreAudioProperty.streamFormat(
                objectID: aggregateID,
                scope: kAudioDevicePropertyScopeInput,
                operation: "read aggregate input format"
            )
            let outputFormat = try CoreAudioProperty.streamFormat(
                objectID: aggregateID,
                scope: kAudioDevicePropertyScopeOutput,
                operation: "read aggregate output format"
            )
            try validate(tapFormat: tapFormat, inputFormat: inputFormat, outputFormat: outputFormat)

            let supportsFloat32PCM = Self.isFloat32PCM(inputFormat) && Self.isFloat32PCM(outputFormat)
            let stats = realtimeStats
            let dsp = realtimeDSP

            var overloadAddress = Self.processorOverloadAddress
            if AudioObjectHasProperty(aggregateID, &overloadAddress) {
                let listener: AudioObjectPropertyListenerBlock = { _, _ in
                    EQRealtimeStatsRecordProcessorOverload(stats)
                }
                try checkOSStatus(
                    AudioObjectAddPropertyListenerBlock(
                        aggregateID,
                        &overloadAddress,
                        overloadQueue,
                        listener
                    ),
                    "observe aggregate processor overloads"
                )
                overloadListener = listener
            }

            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
                    _, inputData, inputTime, outputData, outputTime in
                    EQRealtimeProcess(
                        dsp,
                        stats,
                        inputData,
                        inputTime,
                        outputData,
                        outputTime,
                        supportsFloat32PCM
                    )
                },
                "create aggregate I/O callback"
            )
            guard let ioProcID else {
                throw SpikeError("Core Audio returned no I/O callback identifier.")
            }

            try checkOSStatus(
                AudioDeviceStart(aggregateID, ioProcID),
                "start private aggregate I/O"
            )
            isDeviceStarted = true

            let result = PassThroughConfiguration(
                device: device.replacingBufferFrameSize(physicalBufferFrames),
                requestedBufferFrameSize: Self.lowLatencyBufferFrameSize,
                aggregateBufferFrameSize: aggregateBufferFrames,
                tapFormat: tapFormat,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                aggregateID: aggregateID
            )
            configuration = result
            return result
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if isDeviceStarted, aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        isDeviceStarted = false

        if aggregateID != kAudioObjectUnknown, let overloadListener {
            var overloadAddress = Self.processorOverloadAddress
            AudioObjectRemovePropertyListenerBlock(
                aggregateID,
                &overloadAddress,
                overloadQueue,
                overloadListener
            )
        }
        overloadListener = nil

        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if let bufferRestore {
            try? CoreAudioProperty.setScalar(
                objectID: bufferRestore.deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                value: bufferRestore.frameSize,
                operation: "restore original output-device buffer"
            )
            self.bufferRestore = nil
        }
        configuration = nil
    }

    func setDSPConfiguration(
        coefficients: [BiquadCoefficients],
        preampDb: Double = 0,
        crossfadeFrames: UInt32 = 1_024
    ) throws {
        guard coefficients.count <= Int(EQRealtimeDSPMaximumBandCount) else {
            throw SpikeError("DSP configuration exceeds the 64-band real-time safety limit.")
        }
        guard preampDb.isFinite else {
            throw SpikeError("DSP preamp must be finite.")
        }

        let realtimeCoefficients = coefficients.map(\.realtimeValue)
        let accepted = realtimeCoefficients.withUnsafeBufferPointer { buffer in
            EQRealtimeDSPSetConfiguration(
                realtimeDSP,
                buffer.baseAddress,
                UInt32(buffer.count),
                pow(10, preampDb / 20),
                crossfadeFrames
            )
        }
        guard accepted else {
            throw SpikeError("Real-time DSP rejected invalid or unstable coefficients.")
        }
    }

    func snapshot() -> PassThroughSnapshot {
        let raw = EQRealtimeStatsRead(realtimeStats)
        return PassThroughSnapshot(
            callbackCount: raw.callbackCount,
            frameCount: raw.frameCount,
            formatMismatchCount: raw.formatMismatchCount,
            dspConfigurationApplyCount: raw.dspConfigurationApplyCount,
            nonFiniteOutputCount: raw.nonFiniteOutputCount,
            processorOverloadCount: raw.processorOverloadCount,
            timestampDeltaMilliseconds: AudioTiming.milliseconds(
                nanoseconds: raw.lastTimestampDeltaNanos
            ),
            lastProcessingMilliseconds: AudioTiming.milliseconds(
                nanoseconds: raw.lastProcessingNanos
            ),
            maximumProcessingMilliseconds: AudioTiming.milliseconds(
                nanoseconds: raw.maximumProcessingNanos
            ),
            inputBufferCount: raw.lastInputBufferCount,
            outputBufferCount: raw.lastOutputBufferCount,
            lastFrameCount: raw.lastFrameCount,
            activeBandCount: raw.activeBandCount,
            crossfadeFramesRemaining: raw.crossfadeFramesRemaining
        )
    }

    private func validate(
        tapFormat: AudioStreamBasicDescription,
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription
    ) throws {
        guard Self.isFloat32PCM(tapFormat),
              Self.isFloat32PCM(inputFormat),
              Self.isFloat32PCM(outputFormat) else {
            throw SpikeError("Tap and aggregate must expose 32-bit floating-point PCM.")
        }
        guard inputFormat.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
              inputFormat.mChannelsPerFrame > 0 else {
            throw SpikeError(
                "Input/output channel mismatch: \(inputFormat.mChannelsPerFrame) vs \(outputFormat.mChannelsPerFrame)."
            )
        }
        guard abs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 0.5,
              abs(tapFormat.mSampleRate - outputFormat.mSampleRate) < 0.5 else {
            throw SpikeError(
                "Sample-rate mismatch would require forbidden resampling: tap \(tapFormat.mSampleRate), input \(inputFormat.mSampleRate), output \(outputFormat.mSampleRate)."
            )
        }
    }

    private static func isFloat32PCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM &&
        format.mBitsPerChannel == 32 &&
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    }

    private static var processorOverloadAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

struct SpikeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
