import Foundation

enum EQTextProfileImportError: LocalizedError, Equatable {
    case unreadableText
    case noFilters
    case malformedFilter(String)
    case unsupportedFilterType(String)

    var errorDescription: String? {
        switch self {
        case .unreadableText:
            "EQ profile is not readable UTF-8 text."
        case .noFilters:
            "EQ profile contains no valid Filter lines."
        case .malformedFilter(let line):
            "Malformed EQ filter line: \(line)"
        case .unsupportedFilterType(let type):
            "Unsupported EQ filter type: \(type)"
        }
    }
}

enum EQTextProfileImporter {
    static func decode(
        data: Data,
        name: String,
        deviceUID: String
    ) throws -> EQProfile {
        guard let text = String(data: data, encoding: .utf8) else {
            throw EQTextProfileImportError.unreadableText
        }
        return try decode(text: text, name: name, deviceUID: deviceUID)
    }

    static func decode(
        text: String,
        name: String,
        deviceUID: String
    ) throws -> EQProfile {
        var preampDb = 0.0
        var bands: [EQBand] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            let tokens = tokenize(line)
            guard let first = tokens.first?.lowercased() else { continue }

            if first == "preamp" {
                if let value = firstNumber(in: tokens.dropFirst()) {
                    preampDb = value
                }
                continue
            }
            guard first == "filter" else { continue }
            bands.append(try parseFilter(tokens: tokens, originalLine: line))
        }

        guard !bands.isEmpty else { throw EQTextProfileImportError.noFilters }
        return try EQProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceUID: deviceUID,
            preampDb: preampDb,
            bands: bands
        ).validated()
    }

    private static func parseFilter(tokens: [String], originalLine: String) throws -> EQBand {
        let upper = tokens.map { $0.uppercased() }
        guard let stateIndex = upper.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
              upper.indices.contains(stateIndex + 1),
              let frequency = value(after: "FC", tokens: tokens, upper: upper) else {
            throw EQTextProfileImportError.malformedFilter(originalLine)
        }

        let typeToken = upper[stateIndex + 1]
        let type: BiquadFilterType
        switch typeToken {
        case "PK", "PEQ": type = .peaking
        case "LS", "LSC": type = .lowShelf
        case "HS", "HSC": type = .highShelf
        case "LP", "LPQ": type = .lowPass
        case "HP", "HPQ": type = .highPass
        case "NO", "NOTCH": type = .notch
        default: throw EQTextProfileImportError.unsupportedFilterType(typeToken)
        }

        return EQBand(
            enabled: upper[stateIndex] == "ON",
            type: type,
            frequencyHz: frequency,
            gainDb: value(after: "GAIN", tokens: tokens, upper: upper) ?? 0,
            q: value(after: "Q", tokens: tokens, upper: upper) ?? 0.707_106_781_186_547_6
        )
    }

    private static func tokenize(_ line: String) -> [String] {
        line
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "=", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func value(
        after label: String,
        tokens: [String],
        upper: [String]
    ) -> Double? {
        guard let index = upper.firstIndex(of: label), tokens.indices.contains(index + 1) else {
            return nil
        }
        return Double(tokens[index + 1])
    }

    private static func firstNumber<C: Collection>(in tokens: C) -> Double? where C.Element == String {
        tokens.lazy.compactMap(Double.init).first
    }
}
