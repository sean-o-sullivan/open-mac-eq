import Foundation

enum BiquadFilterType: String, CaseIterable, Codable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    var displayName: String {
        switch self {
        case .peaking: "Bell"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low pass"
        case .highPass: "High pass"
        case .notch: "Notch"
        }
    }

    var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .notch: false
        }
    }
}

struct BiquadParameters: Equatable, Sendable {
    var type: BiquadFilterType
    var frequencyHz: Double
    var gainDb: Double
    var q: Double
    var enabled = true
}

struct BiquadCoefficients: Equatable, Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    var isFinite: Bool {
        [b0, b1, b2, a1, a2].allSatisfy(\.isFinite)
    }

    // Jury stability test for z² + a1*z + a2.
    var isStable: Bool {
        abs(a2) < 1 && 1 + a1 + a2 > 0 && 1 - a1 + a2 > 0
    }

    var realtimeValue: EQBiquadCoefficients {
        EQBiquadCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }
}

enum BiquadDesignError: LocalizedError, Equatable {
    case invalidSampleRate(Double)
    case invalidFrequency(Double, sampleRate: Double)
    case invalidGain(Double)
    case invalidQ(Double)
    case nonFiniteCoefficients
    case unstableCoefficients

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let value):
            "Sample rate must be finite and positive; got \(value)."
        case .invalidFrequency(let value, let sampleRate):
            "Frequency must be finite and between 0 and Nyquist (\(sampleRate / 2) Hz); got \(value)."
        case .invalidGain(let value):
            "Gain must be finite; got \(value)."
        case .invalidQ(let value):
            "Q must be finite and positive; got \(value)."
        case .nonFiniteCoefficients:
            "Filter design produced non-finite coefficients."
        case .unstableCoefficients:
            "Filter design produced an unstable denominator."
        }
    }
}

enum RBJBiquadDesigner {
    static func coefficients(
        for parameters: BiquadParameters,
        sampleRate: Double
    ) throws -> BiquadCoefficients {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BiquadDesignError.invalidSampleRate(sampleRate)
        }
        guard parameters.frequencyHz.isFinite,
              parameters.frequencyHz > 0,
              parameters.frequencyHz < sampleRate / 2 else {
            throw BiquadDesignError.invalidFrequency(parameters.frequencyHz, sampleRate: sampleRate)
        }
        guard parameters.gainDb.isFinite else {
            throw BiquadDesignError.invalidGain(parameters.gainDb)
        }
        guard parameters.q.isFinite, parameters.q > 0 else {
            throw BiquadDesignError.invalidQ(parameters.q)
        }
        guard parameters.enabled else { return .identity }

        let omega = 2 * Double.pi * parameters.frequencyHz / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha = sine / (2 * parameters.q)
        let amplitude = pow(10, parameters.gainDb / 40)

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
        switch parameters.type {
        case .peaking:
            raw = (
                1 + alpha * amplitude,
                -2 * cosine,
                1 - alpha * amplitude,
                1 + alpha / amplitude,
                -2 * cosine,
                1 - alpha / amplitude
            )
        case .lowPass:
            raw = (
                (1 - cosine) / 2,
                1 - cosine,
                (1 - cosine) / 2,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )
        case .highPass:
            raw = (
                (1 + cosine) / 2,
                -(1 + cosine),
                (1 + cosine) / 2,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )
        case .notch:
            raw = (
                1,
                -2 * cosine,
                1,
                1 + alpha,
                -2 * cosine,
                1 - alpha
            )
        case .lowShelf:
            let twoRootAAlpha = 2 * sqrt(amplitude) * alpha
            raw = (
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + twoRootAAlpha),
                2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - twoRootAAlpha),
                (amplitude + 1) + (amplitude - 1) * cosine + twoRootAAlpha,
                -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
                (amplitude + 1) + (amplitude - 1) * cosine - twoRootAAlpha
            )
        case .highShelf:
            let twoRootAAlpha = 2 * sqrt(amplitude) * alpha
            raw = (
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + twoRootAAlpha),
                -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
                amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - twoRootAAlpha),
                (amplitude + 1) - (amplitude - 1) * cosine + twoRootAAlpha,
                2 * ((amplitude - 1) - (amplitude + 1) * cosine),
                (amplitude + 1) - (amplitude - 1) * cosine - twoRootAAlpha
            )
        }

        let result = BiquadCoefficients(
            b0: raw.b0 / raw.a0,
            b1: raw.b1 / raw.a0,
            b2: raw.b2 / raw.a0,
            a1: raw.a1 / raw.a0,
            a2: raw.a2 / raw.a0
        )
        guard result.isFinite else { throw BiquadDesignError.nonFiniteCoefficients }
        guard result.isStable else { throw BiquadDesignError.unstableCoefficients }
        return result
    }
}

private struct DSPComplex {
    var real: Double
    var imaginary: Double

    static let one = DSPComplex(real: 1, imaginary: 0)

    var magnitude: Double { hypot(real, imaginary) }
    var phase: Double { atan2(imaginary, real) }

    static func * (lhs: DSPComplex, rhs: DSPComplex) -> DSPComplex {
        DSPComplex(
            real: lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            imaginary: lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func / (lhs: DSPComplex, rhs: DSPComplex) -> DSPComplex {
        let denominator = rhs.real * rhs.real + rhs.imaginary * rhs.imaginary
        return DSPComplex(
            real: (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            imaginary: (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }
}

struct DSPResponsePoint: Equatable, Sendable {
    let frequencyHz: Double
    let magnitudeDb: Double
    let phaseRadians: Double
}

enum BiquadResponseEvaluator {
    static func evaluate(
        coefficients: [BiquadCoefficients],
        preampDb: Double = 0,
        frequenciesHz: [Double],
        sampleRate: Double
    ) throws -> [DSPResponsePoint] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw BiquadDesignError.invalidSampleRate(sampleRate)
        }
        guard preampDb.isFinite else { throw BiquadDesignError.invalidGain(preampDb) }

        let preamp = pow(10, preampDb / 20)
        var previousWrappedPhase: Double?
        var phaseOffset = 0.0

        return try frequenciesHz.map { frequency in
            guard frequency.isFinite, frequency >= 0, frequency <= sampleRate / 2 else {
                throw BiquadDesignError.invalidFrequency(frequency, sampleRate: sampleRate)
            }
            let omega = 2 * Double.pi * frequency / sampleRate
            let z1 = DSPComplex(real: cos(omega), imaginary: -sin(omega))
            let z2 = z1 * z1
            var total = DSPComplex(real: preamp, imaginary: 0)

            for c in coefficients {
                let numerator = DSPComplex(
                    real: c.b0 + c.b1 * z1.real + c.b2 * z2.real,
                    imaginary: c.b1 * z1.imaginary + c.b2 * z2.imaginary
                )
                let denominator = DSPComplex(
                    real: 1 + c.a1 * z1.real + c.a2 * z2.real,
                    imaginary: c.a1 * z1.imaginary + c.a2 * z2.imaginary
                )
                total = total * (numerator / denominator)
            }

            let wrappedPhase = total.phase
            if let previousWrappedPhase {
                let jump = wrappedPhase - previousWrappedPhase
                if jump > Double.pi {
                    phaseOffset -= 2 * Double.pi
                } else if jump < -Double.pi {
                    phaseOffset += 2 * Double.pi
                }
            }
            previousWrappedPhase = wrappedPhase
            let magnitudeDb = 20 * log10(max(total.magnitude, Double.leastNonzeroMagnitude))
            return DSPResponsePoint(
                frequencyHz: frequency,
                magnitudeDb: magnitudeDb,
                phaseRadians: wrappedPhase + phaseOffset
            )
        }
    }
}

struct BiquadSectionState: Sendable {
    private(set) var z1 = 0.0
    private(set) var z2 = 0.0

    mutating func process(_ input: Double, coefficients c: BiquadCoefficients) -> Double {
        let output = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * output + z2
        z2 = c.b2 * input - c.a2 * output
        return output
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

struct BiquadCascadeProcessor: Sendable {
    let coefficients: [BiquadCoefficients]
    let preampLinear: Double
    private var states: [[BiquadSectionState]]

    init(coefficients: [BiquadCoefficients], preampDb: Double = 0, channelCount: Int) {
        self.coefficients = coefficients
        preampLinear = pow(10, preampDb / 20)
        states = Array(
            repeating: Array(repeating: BiquadSectionState(), count: coefficients.count),
            count: channelCount
        )
    }

    mutating func process(_ input: Double, channel: Int) -> Double {
        precondition(states.indices.contains(channel))
        var sample = input * preampLinear
        for index in coefficients.indices {
            sample = states[channel][index].process(sample, coefficients: coefficients[index])
        }
        return sample
    }

    mutating func reset() {
        for channel in states.indices {
            for band in states[channel].indices {
                states[channel][band].reset()
            }
        }
    }
}
