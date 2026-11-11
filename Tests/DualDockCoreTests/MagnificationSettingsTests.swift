import XCTest
@testable import DualDockCore

final class MagnificationSettingsTests: XCTestCase {
    func testLegacyPeakIsPreservedWithExistingCurveWidth() throws {
        let legacy = Data("{\"version\":7,\"magnificationScale\":1.82,\"magnificationEnabled\":false}".utf8)
        let settings = try JSONDecoder().decode(DockConfiguration.self, from: legacy)
        XCTAssertEqual(settings.magnificationScale, 1.82)
        XCTAssertEqual(settings.magnificationRadius, 2.5)
        XCTAssertFalse(settings.magnificationEnabled)
    }

    func testHeightAndWidthPersistIndependently() throws {
        var settings = DockConfiguration()
        settings.magnificationScale = 2.1
        settings.magnificationRadius = 1.45
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.magnificationScale, 2.1)
        XCTAssertEqual(restored.magnificationRadius, 1.45)
        XCTAssertEqual(restored, settings)
    }

    func testWidthNormalizationDoesNotChangePeak() {
        for (input, expected) in [(-1.0, 1.0), (12.0, 4.0), (Double.nan, 2.5), (Double.infinity, 2.5)] {
            var settings = DockConfiguration()
            settings.magnificationScale = 1.82
            settings.magnificationRadius = input
            settings.normalizeAppearance()
            XCTAssertEqual(settings.magnificationRadius, expected)
            XCTAssertEqual(settings.magnificationScale, 1.82)
        }
    }
}
