import XCTest
@testable import AirPodsEQSpike

final class ReferenceCurveImporterTests: XCTestCase {
    func testImportsCSVHeaderCommentsAndDeduplicatesByFrequency() throws {
        let text = """
        frequency,gain
        # AutoEQ-style correction data
        1000,-2.5
        20,1.0
        1000,-3.0
        20000,0.5
        """
        let curve = try ReferenceCurveImporter.decode(
            data: try XCTUnwrap(text.data(using: .utf8)),
            name: "  AirPods target  "
        )

        XCTAssertEqual(curve.name, "AirPods target")
        XCTAssertEqual(curve.points.map(\.frequencyHz), [20, 1_000, 20_000])
        XCTAssertEqual(curve.points.map(\.gainDb), [1, -3, 0.5])
    }

    func testImportsTabAndWhitespaceSeparatedFiles() throws {
        let tab = "20\t1.5\n1000\t0\n20000\t-1"
        let whitespace = "20 1.5\n1000 0\n20000 -1"

        XCTAssertEqual(
            try ReferenceCurveImporter.decode(data: Data(tab.utf8), name: "Tab").points.count,
            3
        )
        XCTAssertEqual(
            try ReferenceCurveImporter.decode(data: Data(whitespace.utf8), name: "Space").points.count,
            3
        )
    }

    func testRejectsFilesWithoutTwoValidPoints() {
        XCTAssertThrowsError(
            try ReferenceCurveImporter.decode(data: Data("frequency,gain\n1000,0".utf8), name: "Bad")
        ) { error in
            XCTAssertEqual(error as? ReferenceCurveImportError, .tooFewPoints)
        }
    }
}
