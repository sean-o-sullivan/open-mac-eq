import Foundation

enum ReferenceCurveImportError: LocalizedError, Equatable {
    case unreadableText
    case tooFewPoints

    var errorDescription: String? {
        switch self {
        case .unreadableText:
            "Reference curve is not readable UTF-8 text."
        case .tooFewPoints:
            "Reference curve must contain at least two valid frequency/gain rows."
        }
    }
}

enum ReferenceCurveImporter {
    static func decode(data: Data, name: String) throws -> ReferenceCurve {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReferenceCurveImportError.unreadableText
        }

        var pointsByFrequency: [Double: ReferenceCurvePoint] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { continue }
            let fields = split(line)
            guard fields.count >= 2,
                  let frequency = Double(fields[0]),
                  let gain = Double(fields[1]),
                  frequency.isFinite,
                  frequency > 0,
                  gain.isFinite else { continue }
            pointsByFrequency[frequency] = ReferenceCurvePoint(
                frequencyHz: frequency,
                gainDb: gain
            )
            if pointsByFrequency.count > EQProfile.maximumReferenceCurvePointCount {
                throw EQProfileError.tooManyReferenceCurvePoints(pointsByFrequency.count)
            }
        }

        let points = pointsByFrequency.values.sorted { $0.frequencyHz < $1.frequencyHz }
        guard points.count >= 2 else { throw ReferenceCurveImportError.tooFewPoints }
        return ReferenceCurve(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            points: points
        )
    }

    private static func split(_ line: String) -> [String] {
        let delimiter: CharacterSet
        if line.contains("\t") {
            delimiter = .init(charactersIn: "\t")
        } else if line.contains(",") {
            delimiter = .init(charactersIn: ",")
        } else if line.contains(";") {
            delimiter = .init(charactersIn: ";")
        } else {
            delimiter = .whitespaces
        }
        return line
            .components(separatedBy: delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
