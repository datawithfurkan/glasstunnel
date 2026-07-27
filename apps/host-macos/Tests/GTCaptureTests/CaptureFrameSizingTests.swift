#if os(macOS)
import XCTest
@testable import GTCapture

final class CaptureFrameSizingTests: XCTestCase {
    func testScalesLargeDisplaysToPhoneSafeEvenDimensions() {
        let size = CaptureFrameSizing.scaledDimensions(width: 3024, height: 1964, maxDimension: 1280)

        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 830)
    }

    func testKeepsSmallEvenFramesUnchanged() {
        let size = CaptureFrameSizing.scaledDimensions(width: 640, height: 480, maxDimension: 1280)

        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 480)
    }

    func testRoundsOddDimensionsDownForEncoderCompatibility() {
        let size = CaptureFrameSizing.scaledDimensions(width: 801, height: 601, maxDimension: 1280)

        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }
}
#endif
