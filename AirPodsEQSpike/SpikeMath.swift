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

enum AudioTiming {
    static func milliseconds(frames: UInt32, sampleRate: Double) -> Double? {
        guard sampleRate > 0 else { return nil }
        return Double(frames) * 1_000 / sampleRate
    }

    static func milliseconds(nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
