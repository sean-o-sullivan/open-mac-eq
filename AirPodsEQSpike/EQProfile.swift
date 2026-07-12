import Foundation

struct EQBand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var enabled: Bool
    var type: BiquadFilterType
    var frequencyHz: Double
    var gainDb: Double
    var q: Double

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: BiquadFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDb: Double = 0,
        q: Double = 1
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
        self.q = q
    }

    var parameters: BiquadParameters {
        BiquadParameters(
            type: type,
            frequencyHz: frequencyHz,
            gainDb: gainDb,
            q: q,
            enabled: enabled
        )
    }
}

struct ReferenceCurvePoint: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var gainDb: Double
}

struct ReferenceCurve: Codable, Equatable, Sendable {
    var name: String
    var points: [ReferenceCurvePoint]
}

struct EQProfile: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumBandCount = Int(EQRealtimeDSPMaximumBandCount)
    static let maximumReferenceCurvePointCount = 100_000

    var schemaVersion: Int
    var id: UUID
    var name: String
    var deviceUID: String
    var preampDb: Double
    var bands: [EQBand]
    var referenceCurve: ReferenceCurve?

    init(
        schemaVersion: Int = EQProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        deviceUID: String,
        preampDb: Double = 0,
        bands: [EQBand] = [],
        referenceCurve: ReferenceCurve? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.deviceUID = deviceUID
        self.preampDb = preampDb
        self.bands = bands
        self.referenceCurve = referenceCurve
    }

    func validated() throws -> EQProfile {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EQProfileError.unsupportedSchemaVersion(schemaVersion)
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw EQProfileError.emptyName }
        guard !deviceUID.isEmpty else { throw EQProfileError.emptyDeviceUID }
        guard preampDb.isFinite else { throw EQProfileError.invalidPreamp(preampDb) }
        guard bands.count <= Self.maximumBandCount else {
            throw EQProfileError.tooManyBands(bands.count)
        }
        guard Set(bands.map(\.id)).count == bands.count else {
            throw EQProfileError.duplicateBandID
        }

        for band in bands {
            guard band.frequencyHz.isFinite, band.frequencyHz > 0 else {
                throw EQProfileError.invalidBandFrequency(band.id, band.frequencyHz)
            }
            guard band.gainDb.isFinite else {
                throw EQProfileError.invalidBandGain(band.id, band.gainDb)
            }
            guard band.q.isFinite, band.q > 0 else {
                throw EQProfileError.invalidBandQ(band.id, band.q)
            }
        }

        if let referenceCurve {
            guard referenceCurve.points.count <= Self.maximumReferenceCurvePointCount else {
                throw EQProfileError.tooManyReferenceCurvePoints(referenceCurve.points.count)
            }
            let normalizedReferenceName = referenceCurve.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedReferenceName.isEmpty else {
                throw EQProfileError.emptyReferenceCurveName
            }
            var previousFrequency = -Double.infinity
            for point in referenceCurve.points {
                guard point.frequencyHz.isFinite, point.frequencyHz > previousFrequency else {
                    throw EQProfileError.unsortedReferenceCurve
                }
                guard point.gainDb.isFinite else {
                    throw EQProfileError.invalidReferenceCurvePoint
                }
                previousFrequency = point.frequencyHz
            }
        }

        var copy = self
        copy.name = normalizedName
        if var curve = copy.referenceCurve {
            curve.name = curve.name.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.referenceCurve = curve
        }
        return copy
    }

    func coefficients(sampleRate: Double) throws -> [BiquadCoefficients] {
        try validated().bands.map {
            try RBJBiquadDesigner.coefficients(for: $0.parameters, sampleRate: sampleRate)
        }
    }
}

enum EQProfileError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case emptyName
    case emptyDeviceUID
    case invalidPreamp(Double)
    case tooManyBands(Int)
    case duplicateBandID
    case invalidBandFrequency(UUID, Double)
    case invalidBandGain(UUID, Double)
    case invalidBandQ(UUID, Double)
    case emptyReferenceCurveName
    case tooManyReferenceCurvePoints(Int)
    case unsortedReferenceCurve
    case invalidReferenceCurvePoint
    case profileNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Profile schema version \(version) is unsupported. This build supports version \(EQProfile.currentSchemaVersion)."
        case .emptyName:
            "Profile name cannot be empty."
        case .emptyDeviceUID:
            "Profile must be associated with a device UID."
        case .invalidPreamp(let value):
            "Profile preamp must be finite; got \(value)."
        case .tooManyBands(let count):
            "Profile has \(count) bands; the safety limit is \(EQProfile.maximumBandCount)."
        case .duplicateBandID:
            "Profile contains duplicate band identifiers."
        case .invalidBandFrequency(let id, let value):
            "Band \(id) has invalid frequency \(value)."
        case .invalidBandGain(let id, let value):
            "Band \(id) has invalid gain \(value)."
        case .invalidBandQ(let id, let value):
            "Band \(id) has invalid Q \(value)."
        case .emptyReferenceCurveName:
            "Reference curve name cannot be empty."
        case .tooManyReferenceCurvePoints(let count):
            "Reference curve has \(count) points; the safety limit is \(EQProfile.maximumReferenceCurvePointCount)."
        case .unsortedReferenceCurve:
            "Reference-curve frequencies must be positive, unique, and strictly increasing."
        case .invalidReferenceCurvePoint:
            "Reference curve contains a non-finite point."
        case .profileNotFound(let id):
            "Profile \(id) was not found."
        }
    }
}

enum EQProfileCodec {
    static func encode(_ profile: EQProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(profile.validated())
    }

    static func decode(_ data: Data) throws -> EQProfile {
        try JSONDecoder().decode(EQProfile.self, from: data).validated()
    }
}

enum OpenEqApplicationSupport {
    static func directory(
        in baseDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let current = baseDirectory.appendingPathComponent("openEq", isDirectory: true)
        let legacy = baseDirectory.appendingPathComponent("AirPodsEQ", isDirectory: true)
        if !fileManager.fileExists(atPath: current.path),
           fileManager.fileExists(atPath: legacy.path) {
            try fileManager.copyItem(at: legacy, to: current)
        }
        return current
    }
}

final class EQProfileStore {
    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> EQProfileStore {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return EQProfileStore(
            directoryURL: try OpenEqApplicationSupport.directory(
                in: root,
                fileManager: fileManager
            ).appendingPathComponent("Profiles", isDirectory: true),
            fileManager: fileManager
        )
    }

    func save(_ profile: EQProfile) throws -> EQProfile {
        let validated = try profile.validated()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try EQProfileCodec.encode(validated).write(to: url(for: validated.id), options: .atomic)
        return validated
    }

    func load(id: UUID) throws -> EQProfile {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw EQProfileError.profileNotFound(id)
        }
        return try EQProfileCodec.decode(Data(contentsOf: url))
    }

    func loadAll() throws -> [EQProfile] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .map { try EQProfileCodec.decode(Data(contentsOf: $0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func rename(id: UUID, to name: String) throws -> EQProfile {
        var profile = try load(id: id)
        profile.name = name
        return try save(profile)
    }

    func delete(id: UUID) throws {
        let target = url(for: id)
        guard fileManager.fileExists(atPath: target.path) else {
            throw EQProfileError.profileNotFound(id)
        }
        try fileManager.removeItem(at: target)
    }

    private func url(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

enum ProfileAutoApplyBehavior: String, Codable, CaseIterable, Sendable {
    case ask
    case always
    case never
}

struct DeviceProfileAssociation: Codable, Equatable, Sendable {
    var deviceUID: String
    var lastProfileID: UUID?
    var autoApplyBehavior: ProfileAutoApplyBehavior
}

final class DeviceProfileAssociationStore {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> DeviceProfileAssociationStore {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return DeviceProfileAssociationStore(
            fileURL: try OpenEqApplicationSupport.directory(
                in: root,
                fileManager: fileManager
            ).appendingPathComponent("device-associations.json"),
            fileManager: fileManager
        )
    }

    func association(for deviceUID: String) throws -> DeviceProfileAssociation? {
        try loadAll()[deviceUID]
    }

    func save(_ association: DeviceProfileAssociation) throws {
        guard !association.deviceUID.isEmpty else { throw EQProfileError.emptyDeviceUID }
        var all = try loadAll()
        all[association.deviceUID] = association
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(all)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func loadAll() throws -> [String: DeviceProfileAssociation] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode(
            [String: DeviceProfileAssociation].self,
            from: Data(contentsOf: fileURL)
        )
    }
}
