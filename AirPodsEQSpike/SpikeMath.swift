import CoreAudio
import Foundation

enum DeviceClassifier {
    static func isAirPodsPro(name: String, modelUID: String?) -> Bool {
        let searchable = [name, modelUID ?? ""]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return searchable.contains("airpods pro")
    }
}

enum OutputDevicePolicy {
    static func isProcessable(_ device: AudioDeviceDescriptor) -> Bool {
        device.isDefaultOutput && device.isAlive
    }
}

enum AudioBufferPolicy {
    static let lowLatencyFrameSize: UInt32 = 128
    static let bluetoothFrameSize: UInt32 = 256
    static let maximumRecoveryFrameSize: UInt32 = 512

    static func initialFrameSize(transportType: UInt32) -> UInt32 {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return bluetoothFrameSize
        default:
            return lowLatencyFrameSize
        }
    }

    static func recoveryFrameSize(after frameSize: UInt32) -> UInt32 {
        min(max(frameSize * 2, bluetoothFrameSize), maximumRecoveryFrameSize)
    }
}

enum AudioRecoveryTrigger: Equatable {
    case processorOverloadBurst(count: Int)
    case callbackStall(seconds: TimeInterval)

    var description: String {
        switch self {
        case let .processorOverloadBurst(count):
            return "Core Audio reported \(count) overloads inside the recovery window"
        case let .callbackStall(seconds):
            return String(format: "audio callbacks stalled for %.1f seconds", seconds)
        }
    }
}

struct AudioReliabilityMonitor {
    private let overloadThreshold: Int
    private let overloadWindowSeconds: TimeInterval
    private let callbackStallSeconds: TimeInterval
    private var previousCallbackCount: UInt64?
    private var previousOverloadCount: UInt64?
    private var lastCallbackAdvanceTime: TimeInterval?
    private var overloadTimes: [TimeInterval] = []

    init(
        overloadThreshold: Int = 3,
        overloadWindowSeconds: TimeInterval = 10,
        callbackStallSeconds: TimeInterval = 2
    ) {
        self.overloadThreshold = overloadThreshold
        self.overloadWindowSeconds = overloadWindowSeconds
        self.callbackStallSeconds = callbackStallSeconds
    }

    mutating func reset(
        callbackCount: UInt64 = 0,
        overloadCount: UInt64 = 0,
        now: TimeInterval
    ) {
        previousCallbackCount = callbackCount
        previousOverloadCount = overloadCount
        lastCallbackAdvanceTime = now
        overloadTimes.removeAll(keepingCapacity: true)
    }

    mutating func observe(
        callbackCount: UInt64,
        overloadCount: UInt64,
        expectsCallbacks: Bool,
        now: TimeInterval
    ) -> AudioRecoveryTrigger? {
        if let previousOverloadCount {
            if overloadCount >= previousOverloadCount {
                let delta = min(
                    overloadCount - previousOverloadCount,
                    UInt64(overloadThreshold)
                )
                for _ in 0..<Int(delta) {
                    overloadTimes.append(now)
                }
            } else {
                overloadTimes.removeAll(keepingCapacity: true)
            }
        }
        previousOverloadCount = overloadCount
        overloadTimes.removeAll { now - $0 > overloadWindowSeconds }

        if overloadTimes.count >= overloadThreshold {
            let count = overloadTimes.count
            overloadTimes.removeAll(keepingCapacity: true)
            previousCallbackCount = callbackCount
            lastCallbackAdvanceTime = now
            return .processorOverloadBurst(count: count)
        }

        if previousCallbackCount != callbackCount {
            previousCallbackCount = callbackCount
            lastCallbackAdvanceTime = now
        } else if previousCallbackCount == nil {
            previousCallbackCount = callbackCount
            lastCallbackAdvanceTime = now
        }

        guard expectsCallbacks else {
            lastCallbackAdvanceTime = now
            return nil
        }

        let stalledFor = now - (lastCallbackAdvanceTime ?? now)
        guard stalledFor >= callbackStallSeconds else { return nil }
        lastCallbackAdvanceTime = now
        return .callbackStall(seconds: stalledFor)
    }
}

enum AudioTiming {
    static func milliseconds(frames: UInt32, sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        return Double(frames) * 1_000 / sampleRate
    }

    static func milliseconds(nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}

enum AudioLevel {
    static func decibelsFS(magnitude: Double) -> Double? {
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return 20 * log10(magnitude)
    }
}
