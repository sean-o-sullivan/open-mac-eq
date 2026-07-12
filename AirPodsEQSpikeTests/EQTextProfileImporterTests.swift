import XCTest
@testable import AirPodsEQSpike

final class EQTextProfileImporterTests: XCTestCase {
    private let suppliedProfile = """
    Preamp: -3.9 dB
    Filter 1: ON PK Fc 40 Hz Gain -2.3 dB Q 0.70
    Filter 2: ON PK Fc 151 Hz Gain +3.7 dB Q 1.41
    Filter 3: ON PK Fc 3417 Hz Gain +3.9 dB Q 3.00
    Filter 4: ON PK Fc 4305 Hz Gain +1.5 dB Q 2.00
    Filter 5: ON PK Fc 5747 Hz Gain -6.4 dB Q 3.00
    Filter 6: ON PK Fc 7671 Hz Gain -2.9 dB Q 1.41
    """

    func testImportsSuppliedSongbirdSixBandProfileExactly() throws {
        let profile = try EQTextProfileImporter.decode(
            text: suppliedProfile,
            name: "AirPods Pro 3 — Songbird JM-1",
            deviceUID: "airpods-uid"
        )

        assertSongbirdProfile(profile)
    }

    func testBundledSongbirdSixBandProfileMatchesPublishedValues() throws {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "airpods-pro-3-songbird-jm1-6band",
            withExtension: "txt"
        ))
        let profile = try EQTextProfileImporter.decode(
            data: Data(contentsOf: url),
            name: "AirPods Pro 3 — Songbird JM-1",
            deviceUID: "airpods-uid"
        )

        assertSongbirdProfile(profile)
    }

    private func assertSongbirdProfile(
        _ profile: EQProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(profile.preampDb, -3.9, file: file, line: line)
        XCTAssertEqual(profile.bands.count, 6, file: file, line: line)
        XCTAssertEqual(
            profile.bands.map(\.type),
            Array(repeating: .peaking, count: 6),
            file: file,
            line: line
        )
        XCTAssertEqual(
            profile.bands.map(\.frequencyHz),
            [40, 151, 3_417, 4_305, 5_747, 7_671],
            file: file,
            line: line
        )
        XCTAssertEqual(
            profile.bands.map(\.gainDb),
            [-2.3, 3.7, 3.9, 1.5, -6.4, -2.9],
            file: file,
            line: line
        )
        XCTAssertEqual(
            profile.bands.map(\.q),
            [0.7, 1.41, 3, 2, 3, 1.41],
            file: file,
            line: line
        )
        XCTAssertTrue(profile.bands.allSatisfy(\.enabled), file: file, line: line)
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
