import XCTest
@testable import AirPodsEQSpike

final class SpikeMathTests: XCTestCase {
    func testAirPodsProClassificationIsCaseInsensitive() {
        XCTAssertTrue(DeviceClassifier.isAirPodsPro(name: "Example AirPods Pro", modelUID: nil))
        XCTAssertTrue(DeviceClassifier.isAirPodsPro(name: "Headphones", modelUID: "APPLE AIRPODS PRO 2"))
        XCTAssertFalse(DeviceClassifier.isAirPodsPro(name: "AirPods Max", modelUID: nil))
        XCTAssertFalse(DeviceClassifier.isAirPodsPro(name: "Built-in Output", modelUID: nil))
    }

    func testAnyLiveDefaultOutputIsProcessable() {
        let builtIn = outputDevice(name: "Built-in Speakers", isDefaultOutput: true, isAlive: true)
        let usb = outputDevice(name: "USB DAC", isDefaultOutput: true, isAlive: true)
        let nonDefault = outputDevice(name: "Other Headphones", isDefaultOutput: false, isAlive: true)
        let unavailable = outputDevice(name: "Disconnected DAC", isDefaultOutput: true, isAlive: false)

        XCTAssertTrue(OutputDevicePolicy.isProcessable(builtIn))
        XCTAssertTrue(OutputDevicePolicy.isProcessable(usb))
        XCTAssertFalse(OutputDevicePolicy.isProcessable(nonDefault))
        XCTAssertFalse(OutputDevicePolicy.isProcessable(unavailable))
    }

    func testFrameDurationAt48kHz() throws {
        XCTAssertEqual(try XCTUnwrap(AudioTiming.milliseconds(frames: 128, sampleRate: 48_000)), 2.666_666, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AudioTiming.milliseconds(frames: 256, sampleRate: 48_000)), 5.333_333, accuracy: 0.000_001)
        XCTAssertNil(AudioTiming.milliseconds(frames: 256, sampleRate: 0))
    }

    func testBluetoothUsesSaferInitialBuffer() {
        XCTAssertEqual(
            AudioBufferPolicy.initialFrameSize(transportType: kAudioDeviceTransportTypeBluetooth),
            256
        )
        XCTAssertEqual(
            AudioBufferPolicy.initialFrameSize(transportType: kAudioDeviceTransportTypeBluetoothLE),
            256
        )
        XCTAssertEqual(
            AudioBufferPolicy.initialFrameSize(transportType: kAudioDeviceTransportTypeBuiltIn),
            128
        )
        XCTAssertEqual(AudioBufferPolicy.recoveryFrameSize(after: 128), 256)
        XCTAssertEqual(AudioBufferPolicy.recoveryFrameSize(after: 256), 512)
        XCTAssertEqual(AudioBufferPolicy.recoveryFrameSize(after: 512), 512)
    }

    func testReliabilityMonitorDetectsOverloadBurst() {
        var monitor = AudioReliabilityMonitor()
        monitor.reset(now: 0)

        XCTAssertNil(monitor.observe(
            callbackCount: 100,
            overloadCount: 1,
            expectsCallbacks: true,
            now: 1
        ))
        XCTAssertNil(monitor.observe(
            callbackCount: 200,
            overloadCount: 2,
            expectsCallbacks: true,
            now: 5
        ))
        XCTAssertEqual(monitor.observe(
            callbackCount: 300,
            overloadCount: 3,
            expectsCallbacks: true,
            now: 9
        ), .processorOverloadBurst(count: 3))
    }

    func testReliabilityMonitorExpiresOldOverloads() {
        var monitor = AudioReliabilityMonitor()
        monitor.reset(now: 0)

        XCTAssertNil(monitor.observe(
            callbackCount: 100,
            overloadCount: 2,
            expectsCallbacks: true,
            now: 1
        ))
        XCTAssertNil(monitor.observe(
            callbackCount: 200,
            overloadCount: 3,
            expectsCallbacks: true,
            now: 12
        ))
    }

    func testReliabilityMonitorDetectsCallbackStallOnlyWhileExpected() {
        var monitor = AudioReliabilityMonitor(callbackStallSeconds: 2)
        monitor.reset(callbackCount: 100, now: 0)

        XCTAssertNil(monitor.observe(
            callbackCount: 100,
            overloadCount: 0,
            expectsCallbacks: false,
            now: 3
        ))
        XCTAssertNil(monitor.observe(
            callbackCount: 100,
            overloadCount: 0,
            expectsCallbacks: true,
            now: 4
        ))
        let trigger = monitor.observe(
            callbackCount: 100,
            overloadCount: 0,
            expectsCallbacks: true,
            now: 5.1
        )
        guard case let .callbackStall(seconds)? = trigger else {
            return XCTFail("Expected a callback-stall trigger")
        }
        XCTAssertEqual(seconds, 2.1, accuracy: 0.000_001)
    }

    func testReliabilityMonitorDefaultAllowsTemporarySchedulingStall() {
        var monitor = AudioReliabilityMonitor()
        monitor.reset(callbackCount: 100, now: 0)

        XCTAssertNil(monitor.observe(
            callbackCount: 100,
            overloadCount: 0,
            expectsCallbacks: true,
            now: 4.9
        ))
        XCTAssertEqual(monitor.observe(
            callbackCount: 100,
            overloadCount: 0,
            expectsCallbacks: true,
            now: 5.1
        ), .callbackStall(seconds: 5.1))
    }

    func testRecoveryIsDeferredDuringMemoryPressure() {
        XCTAssertEqual(
            AudioRecoveryPolicy.action(
                for: .callbackStall(seconds: 6),
                currentFrameSize: 256,
                memoryPressure: .warning
            ),
            .deferUntilPressureClears
        )
        XCTAssertEqual(
            AudioRecoveryPolicy.action(
                for: .processorOverloadBurst(count: 3),
                currentFrameSize: 256,
                memoryPressure: .critical
            ),
            .deferUntilPressureClears
        )
    }

    func testRecoveryEscalatesBufferOnlyWhenUseful() {
        XCTAssertEqual(
            AudioRecoveryPolicy.action(
                for: .processorOverloadBurst(count: 3),
                currentFrameSize: 256,
                memoryPressure: .normal
            ),
            .rebuild(frameSize: 512)
        )
        XCTAssertEqual(
            AudioRecoveryPolicy.action(
                for: .processorOverloadBurst(count: 3),
                currentFrameSize: 512,
                memoryPressure: .normal
            ),
            .keepCurrentRoute
        )
        XCTAssertEqual(
            AudioRecoveryPolicy.action(
                for: .callbackStall(seconds: 6),
                currentFrameSize: 512,
                memoryPressure: .normal
            ),
            .rebuild(frameSize: 512)
        )
    }

    func testAudioLevelConversion() throws {
        XCTAssertEqual(try XCTUnwrap(AudioLevel.decibelsFS(magnitude: 1)), 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(AudioLevel.decibelsFS(magnitude: 0.5)), -6.0206, accuracy: 0.0001)
        XCTAssertNil(AudioLevel.decibelsFS(magnitude: 0))
        XCTAssertNil(AudioLevel.decibelsFS(magnitude: .infinity))
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

    private func outputDevice(
        name: String,
        isDefaultOutput: Bool,
        isAlive: Bool
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            id: 1,
            uid: name,
            name: name,
            modelUID: nil,
            transportType: 0,
            isDefaultOutput: isDefaultOutput,
            isAlive: isAlive,
            sampleRate: 48_000,
            bufferFrameSize: 128,
            deviceLatencyFrames: 0,
            safetyOffsetFrames: 0
        )
    }
}
