import AppKit
import XCTest
@testable import EdgeeWidget

@MainActor
final class BrandAssetsTests: XCTestCase {
    func testOfficialVectorAssetsLoadFromResourceBundle() {
        for name in ["EdgeeMark", "EdgeeWordmark"] {
            let image = BrandAssets.image(named: name)
            XCTAssertTrue(image.isValid, "\(name) must be present and readable")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep }, "Keep official artwork resolution independent")
        }
    }

    func testMenuBarMarkUsesNativeTemplateRendering() {
        let image = BrandAssets.menuBarIcon
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }
}
