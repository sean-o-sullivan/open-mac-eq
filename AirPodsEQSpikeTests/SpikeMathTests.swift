import XCTest
@testable import AirPodsEQSpike

final class SpikeMathTests: XCTestCase {
    func testAirPodsProClassificationIsCaseInsensitive() {
        XCTAssertTrue(DeviceClassifier.isAirPodsPro(name: "Example AirPods Pro", modelUID: nil))
        XCTAssertTrue(DeviceClassifier.isAirPodsPro(name: "Headphones", modelUID: "APPLE AIRPODS PRO 2"))
        XCTAssertFalse(DeviceClassifier.isAirPodsPro(name: "AirPods Max", modelUID: nil))
        XCTAssertFalse(DeviceClassifier.isAirPodsPro(name: "Built-in Output", modelUID: nil))
    }

    func testFrameDurationAt48kHz() throws {
        XCTAssertEqual(try XCTUnwrap(AudioTiming.milliseconds(frames: 128, sampleRate: 48_000)), 2.666_666, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AudioTiming.milliseconds(frames: 256, sampleRate: 48_000)), 5.333_333, accuracy: 0.000_001)
        XCTAssertNil(AudioTiming.milliseconds(frames: 256, sampleRate: 0))
    }

    func testNanosecondsToMilliseconds() {
        XCTAssertEqual(AudioTiming.milliseconds(nanoseconds: 2_500_000), 2.5, accuracy: 0.000_001)
    }

    func testRealtimeBridgeConvertsPlanarToInterleaved() {
        XCTAssertTrue(EQRealtimeBridgeSelfTest())
    }

    func testRealtimeDSPBridgeProcessesKnownImpulse() {
        XCTAssertTrue(EQRealtimeDSPImpulseSelfTest())
    }

    func testRealtimeDSPCrossfadesParameterUpdates() {
        XCTAssertTrue(EQRealtimeDSPCrossfadeSelfTest())
    }
}
