import XCTest
@testable import AirPodsEQSpike

final class EQProfileTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testProfileJSONRoundTripPreservesBandsAndReferenceCurve() throws {
        let profile = sampleProfile()
        let decoded = try EQProfileCodec.decode(EQProfileCodec.encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testDecoderIgnoresUnknownFutureFieldsAtKnownSchemaVersion() throws {
        let id = UUID()
        let bandID = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id.uuidString)",
          "name": "Unknown fields",
          "deviceUID": "device-1",
          "preampDb": -3.0,
          "futureTopLevelValue": {"anything": true},
          "bands": [{
            "id": "\(bandID.uuidString)",
            "enabled": true,
            "type": "peaking",
            "frequencyHz": 1000.0,
            "gainDb": 2.0,
            "q": 1.0,
            "futureBandValue": 42
          }]
        }
        """

        let profile = try EQProfileCodec.decode(try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.bands.first?.id, bandID)
    }

    func testRejectsUnsupportedNewerSchema() throws {
        var profile = sampleProfile()
        profile.schemaVersion = 2
        let data = try JSONEncoder().encode(profile)

        XCTAssertThrowsError(try EQProfileCodec.decode(data)) { error in
            XCTAssertEqual(error as? EQProfileError, .unsupportedSchemaVersion(2))
        }
    }

    func testProfileStoreSaveLoadRenameListAndDelete() throws {
        let directory = temporaryDirectory().appendingPathComponent("Profiles")
        let store = EQProfileStore(directoryURL: directory)
        let first = sampleProfile(name: "Zulu")
        let second = sampleProfile(name: "Alpha")

        XCTAssertEqual(try store.save(first), first)
        XCTAssertEqual(try store.save(second), second)
        XCTAssertEqual(try store.load(id: first.id), first)
        XCTAssertEqual(try store.loadAll().map(\.name), ["Alpha", "Zulu"])

        let renamed = try store.rename(id: first.id, to: "Middle")
        XCTAssertEqual(renamed.name, "Middle")
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(try store.loadAll().map(\.name), ["Alpha", "Middle"])

        try store.delete(id: second.id)
        XCTAssertEqual(try store.loadAll().map(\.id), [first.id])
        XCTAssertThrowsError(try store.load(id: second.id))
    }

    func testDeviceAssociationsAreKeyedByExactUID() throws {
        let file = temporaryDirectory().appendingPathComponent("associations.json")
        let store = DeviceProfileAssociationStore(fileURL: file)
        let profileID = UUID()
        let first = DeviceProfileAssociation(
            deviceUID: "airpods-pairing-a",
            lastProfileID: profileID,
            autoApplyBehavior: .always
        )
        let second = DeviceProfileAssociation(
            deviceUID: "airpods-pairing-b",
            lastProfileID: nil,
            autoApplyBehavior: .never
        )

        try store.save(first)
        try store.save(second)
        XCTAssertEqual(try store.association(for: first.deviceUID), first)
        XCTAssertEqual(try store.association(for: second.deviceUID), second)
        XCTAssertNil(try store.association(for: "renamed-display-name"))
    }

    func testApplicationSupportMigrationCopiesLegacyProfilesWithoutDeletingThem() throws {
        let base = temporaryDirectory()
        let legacy = base.appendingPathComponent("AirPodsEQ", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let marker = legacy.appendingPathComponent("legacy-profile.json")
        try Data("legacy".utf8).write(to: marker)

        let current = try OpenEqApplicationSupport.directory(in: base)

        XCTAssertEqual(current.lastPathComponent, "openEq")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("legacy-profile.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLegacyBundledPresetMigrationOnlyReplacesExactCopies() throws {
        let frequencies: [Double] = [
            38, 143, 479, 973, 1_299, 1_522, 3_320, 4_064, 5_915, 7_671,
        ]
        let gains: [Double] = [
            -2.5, 4.1, 0.8, -1.3, 0.9, 1.1, 3.7, 1.7, -5.8, -1.9,
        ]
        let qualities: [Double] = [
            0.6, 1.25, 0.9, 2.85, 4.05, 4.1, 2.95, 3.65, 2.3, 2.1,
        ]
        let originalID = UUID()
        let legacy = EQProfile(
            id: originalID,
            name: "Renamed legacy copy",
            deviceUID: "device-a",
            preampDb: -3.8,
            bands: frequencies.indices.map { index in
                EQBand(
                    type: .peaking,
                    frequencyHz: frequencies[index],
                    gainDb: gains[index],
                    q: qualities[index]
                )
            }
        )
        let replacement = EQProfile(
            name: "AirPods Pro 3 — Songbird JM-1 6-band",
            deviceUID: "template-device",
            preampDb: -3.9,
            bands: [EQBand(frequencyHz: 40, gainDb: -2.3, q: 0.7)]
        )

        let migrated = try XCTUnwrap(
            LegacyBundledPresetMigration.replacingExactLegacyPreset(
                legacy,
                with: replacement
            )
        )
        XCTAssertEqual(migrated.id, originalID)
        XCTAssertEqual(migrated.deviceUID, "device-a")
        XCTAssertEqual(migrated.name, replacement.name)
        XCTAssertEqual(migrated.preampDb, -3.9)
        XCTAssertEqual(migrated.bands, replacement.bands)

        var customized = legacy
        customized.bands[0].gainDb = -2.4
        XCTAssertNil(LegacyBundledPresetMigration.replacingExactLegacyPreset(
            customized,
            with: replacement
        ))
    }

    func testValidationRejectsMalformedCurveAndDuplicateBandIDs() throws {
        let duplicateID = UUID()
        var profile = sampleProfile()
        profile.bands = [
            EQBand(id: duplicateID, frequencyHz: 100),
            EQBand(id: duplicateID, frequencyHz: 1_000),
        ]
        XCTAssertThrowsError(try profile.validated()) { error in
            XCTAssertEqual(error as? EQProfileError, .duplicateBandID)
        }

        profile = sampleProfile()
        profile.referenceCurve = ReferenceCurve(
            name: "Bad ordering",
            points: [
                ReferenceCurvePoint(frequencyHz: 1_000, gainDb: 0),
                ReferenceCurvePoint(frequencyHz: 100, gainDb: 1),
            ]
        )
        XCTAssertThrowsError(try profile.validated()) { error in
            XCTAssertEqual(error as? EQProfileError, .unsortedReferenceCurve)
        }
    }

    private func sampleProfile(name: String = "AirPods neutral") -> EQProfile {
        EQProfile(
            id: UUID(),
            name: name,
            deviceUID: "AppleUSBAudioEngine:AirPods-Pro-UID",
            preampDb: -3.5,
            bands: [
                EQBand(type: .lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.707),
                EQBand(type: .peaking, frequencyHz: 2_500, gainDb: -3, q: 1.4),
                EQBand(type: .highPass, frequencyHz: 25, gainDb: 0, q: 0.707),
            ],
            referenceCurve: ReferenceCurve(
                name: "Target",
                points: [
                    ReferenceCurvePoint(frequencyHz: 20, gainDb: 1),
                    ReferenceCurvePoint(frequencyHz: 1_000, gainDb: 0),
                    ReferenceCurvePoint(frequencyHz: 20_000, gainDb: -1),
                ]
            )
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirPodsEQTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
