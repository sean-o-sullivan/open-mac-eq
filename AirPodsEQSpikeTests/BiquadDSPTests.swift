import XCTest
@testable import AirPodsEQSpike

final class BiquadDSPTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testPeakingGoldenCoefficientsMatchRBJCookbook() throws {
        let coefficients = try design(.peaking, frequency: 1_000, gain: 3, q: 1)

        XCTAssertEqual(coefficients.b0, 1.021_474_096_402_299, accuracy: 1e-14)
        XCTAssertEqual(coefficients.b1, -1.879_673_020_131_260, accuracy: 1e-14)
        XCTAssertEqual(coefficients.b2, 0.874_418_548_123_250, accuracy: 1e-14)
        XCTAssertEqual(coefficients.a1, -1.879_673_020_131_260, accuracy: 1e-14)
        XCTAssertEqual(coefficients.a2, 0.895_892_644_525_550, accuracy: 1e-14)
    }

    func testButterworthLowPassGoldenCoefficients() throws {
        let coefficients = try design(
            .lowPass,
            frequency: 5_000,
            gain: 0,
            q: 1 / sqrt(2)
        )

        XCTAssertEqual(coefficients.b0, 0.072_230_875_325_753, accuracy: 1e-14)
        XCTAssertEqual(coefficients.b1, 0.144_461_750_651_506, accuracy: 1e-14)
        XCTAssertEqual(coefficients.b2, 0.072_230_875_325_753, accuracy: 1e-14)
        XCTAssertEqual(coefficients.a1, -1.109_228_792_618_427, accuracy: 1e-14)
        XCTAssertEqual(coefficients.a2, 0.398_152_293_921_440, accuracy: 1e-14)
    }

    func testEachFilterHasExpectedAnchorResponse() throws {
        let peaking = try magnitude(try design(.peaking, frequency: 1_000, gain: 6, q: 1), at: 1_000)
        XCTAssertEqual(peaking, 6, accuracy: 1e-10)

        let lowShelf = try design(.lowShelf, frequency: 500, gain: 6, q: 0.707)
        XCTAssertEqual(try magnitude(lowShelf, at: 0), 6, accuracy: 1e-9)
        XCTAssertEqual(try magnitude(lowShelf, at: sampleRate / 2), 0, accuracy: 1e-9)

        let highShelf = try design(.highShelf, frequency: 5_000, gain: -6, q: 0.707)
        XCTAssertEqual(try magnitude(highShelf, at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(try magnitude(highShelf, at: sampleRate / 2), -6, accuracy: 1e-9)

        let lowPass = try design(.lowPass, frequency: 2_000, gain: 0, q: 0.707)
        XCTAssertEqual(try magnitude(lowPass, at: 0), 0, accuracy: 1e-9)
        XCTAssertLessThan(try magnitude(lowPass, at: 23_000), -50)

        let highPass = try design(.highPass, frequency: 2_000, gain: 0, q: 0.707)
        XCTAssertLessThan(try magnitude(highPass, at: 20), -70)
        XCTAssertEqual(try magnitude(highPass, at: sampleRate / 2), 0, accuracy: 1e-9)

        let notch = try design(.notch, frequency: 3_000, gain: 0, q: 2)
        XCTAssertLessThan(try magnitude(notch, at: 3_000), -250)
        XCTAssertEqual(try magnitude(notch, at: 0), 0, accuracy: 1e-9)
    }

    func testCascadeMultipliesTransferFunctionsInsteadOfSummingOutputs() throws {
        let first = try design(.peaking, frequency: 1_000, gain: 3, q: 1)
        let second = try design(.peaking, frequency: 1_000, gain: 3, q: 1)
        let cascaded = try XCTUnwrap(
            BiquadResponseEvaluator.evaluate(
                coefficients: [first, second],
                frequenciesHz: [1_000],
                sampleRate: sampleRate
            ).first
        ).magnitudeDb

        let incorrectParallelSum = 20 * log10(2 * pow(10, 3.0 / 20))
        XCTAssertEqual(cascaded, 6, accuracy: 1e-10)
        XCTAssertEqual(incorrectParallelSum, 9.020_599_913_279_625, accuracy: 1e-12)
        XCTAssertNotEqual(cascaded, incorrectParallelSum, accuracy: 1)
    }

    func testTimeDomainImpulseMatchesDifferenceEquation() throws {
        let coefficients = try design(.peaking, frequency: 1_000, gain: 3, q: 1)
        var processor = BiquadCascadeProcessor(
            coefficients: [coefficients],
            channelCount: 1
        )
        let actual = (0..<4).map { index in
            processor.process(index == 0 ? 1 : 0, channel: 0)
        }

        let y0 = coefficients.b0
        let y1 = coefficients.b1 - coefficients.a1 * y0
        let y2 = coefficients.b2 - coefficients.a1 * y1 - coefficients.a2 * y0
        let y3 = -coefficients.a1 * y2 - coefficients.a2 * y1
        let expected = [y0, y1, y2, y3]

        for (actualSample, expectedSample) in zip(actual, expected) {
            XCTAssertEqual(actualSample, expectedSample, accuracy: 1e-14)
        }
    }

    func testIndependentChannelState() throws {
        let coefficients = try design(.lowPass, frequency: 1_000, gain: 0, q: 0.707)
        var processor = BiquadCascadeProcessor(
            coefficients: [coefficients],
            channelCount: 2
        )

        _ = processor.process(1, channel: 0)
        XCTAssertEqual(processor.process(0, channel: 1), 0, accuracy: 0)
        XCTAssertNotEqual(processor.process(0, channel: 0), 0, accuracy: 1e-15)
    }

    func testDesignsRemainFiniteAndStableAcrossUsefulExtremes() throws {
        for type in BiquadFilterType.allCases {
            for frequency in [20.0, 1_000, 20_000] {
                for q in [0.1, 0.707, 1, 20] {
                    for gain in [-24.0, 0, 24] {
                        let coefficients = try design(type, frequency: frequency, gain: gain, q: q)
                        XCTAssertTrue(coefficients.isFinite, "\(type), f=\(frequency), q=\(q), gain=\(gain)")
                        XCTAssertTrue(coefficients.isStable, "\(type), f=\(frequency), q=\(q), gain=\(gain)")
                    }
                }
            }
        }
    }

    func testRejectsInvalidParameters() {
        XCTAssertThrowsError(try design(.peaking, frequency: 0, gain: 3, q: 1))
        XCTAssertThrowsError(try design(.peaking, frequency: 24_000, gain: 3, q: 1))
        XCTAssertThrowsError(try design(.peaking, frequency: 1_000, gain: .nan, q: 1))
        XCTAssertThrowsError(try design(.peaking, frequency: 1_000, gain: 3, q: 0))
    }

    private func design(
        _ type: BiquadFilterType,
        frequency: Double,
        gain: Double,
        q: Double
    ) throws -> BiquadCoefficients {
        try RBJBiquadDesigner.coefficients(
            for: BiquadParameters(
                type: type,
                frequencyHz: frequency,
                gainDb: gain,
                q: q
            ),
            sampleRate: sampleRate
        )
    }

    private func magnitude(_ coefficients: BiquadCoefficients, at frequency: Double) throws -> Double {
        try XCTUnwrap(
            BiquadResponseEvaluator.evaluate(
                coefficients: [coefficients],
                frequenciesHz: [frequency],
                sampleRate: sampleRate
            ).first
        ).magnitudeDb
    }
}
