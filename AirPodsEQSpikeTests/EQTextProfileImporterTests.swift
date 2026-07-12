import XCTest
@testable import AirPodsEQSpike

final class EQTextProfileImporterTests: XCTestCase {
    private let suppliedProfile = """
    Preamp: -3.8 dB
    Filter 1:  ON PK Fc    38 Hz Gain -2.5 dB Q 0.60
    Filter 2:  ON PK Fc   143 Hz Gain +4.1 dB Q 1.25
    Filter 3:  ON PK Fc   479 Hz Gain +0.8 dB Q 0.90
    Filter 4:  ON PK Fc   973 Hz Gain -1.3 dB Q 2.85
    Filter 5:  ON PK Fc  1299 Hz Gain +0.9 dB Q 4.05
    Filter 6:  ON PK Fc  1522 Hz Gain +1.1 dB Q 4.10
    Filter 7:  ON PK Fc  3320 Hz Gain +3.7 dB Q 2.95
    Filter 8:  ON PK Fc  4064 Hz Gain +1.7 dB Q 3.65
    Filter 9:  ON PK Fc  5915 Hz Gain -5.8 dB Q 2.30
    Filter 10: ON PK Fc  7671 Hz Gain -1.9 dB Q 2.10
    """

    func testImportsSuppliedTenBandProfileExactly() throws {
        let profile = try EQTextProfileImporter.decode(
            text: suppliedProfile,
            name: "AirPods Pro 3 — JM-1",
            deviceUID: "airpods-uid"
        )

        XCTAssertEqual(profile.preampDb, -3.8)
        XCTAssertEqual(profile.bands.count, 10)
        XCTAssertEqual(profile.bands.map(\.type), Array(repeating: .peaking, count: 10))
        XCTAssertEqual(profile.bands.map(\.frequencyHz), [38, 143, 479, 973, 1_299, 1_522, 3_320, 4_064, 5_915, 7_671])
        XCTAssertEqual(profile.bands.map(\.gainDb), [-2.5, 4.1, 0.8, -1.3, 0.9, 1.1, 3.7, 1.7, -5.8, -1.9])
        XCTAssertEqual(profile.bands.map(\.q), [0.6, 1.25, 0.9, 2.85, 4.05, 4.1, 2.95, 3.65, 2.3, 2.1])
        XCTAssertTrue(profile.bands.allSatisfy(\.enabled))
    }

    func testImportsSupportedTypesDisabledStateAndDefaults() throws {
        let text = """
        Filter 1: OFF LS Fc 100 Hz Gain 2 dB Q 0.8
        Filter 2: ON HS Fc 8000 Hz Gain -1.5 dB Q 1
        Filter 3: ON LP Fc 18000 Hz Q 0.707
        Filter 4: ON HP Fc 30 Hz Q 0.707
        Filter 5: ON NO Fc 3000 Hz Q 4
        """
        let profile = try EQTextProfileImporter.decode(text: text, name: "Types", deviceUID: "uid")

        XCTAssertEqual(profile.bands.map(\.type), [.lowShelf, .highShelf, .lowPass, .highPass, .notch])
        XCTAssertFalse(profile.bands[0].enabled)
        XCTAssertEqual(profile.bands[2].gainDb, 0)
    }

    func testRejectsMissingAndUnsupportedFilters() {
        XCTAssertThrowsError(
            try EQTextProfileImporter.decode(text: "Preamp: -3 dB", name: "Empty", deviceUID: "uid")
        ) { error in
            XCTAssertEqual(error as? EQTextProfileImportError, .noFilters)
        }
        XCTAssertThrowsError(
            try EQTextProfileImporter.decode(
                text: "Filter 1: ON BP Fc 1000 Hz Q 1",
                name: "Bad",
                deviceUID: "uid"
            )
        ) { error in
            XCTAssertEqual(error as? EQTextProfileImportError, .unsupportedFilterType("BP"))
        }
    }
}
