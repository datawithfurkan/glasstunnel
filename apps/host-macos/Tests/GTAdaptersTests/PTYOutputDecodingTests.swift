import Foundation
import XCTest
@testable import GTAdapters

final class PTYOutputDecodingTests: XCTestCase {
    func testWholeChunkDecodesWithNothingPending() {
        let (text, rest) = PTYAdapterBase.decodeUTF8Prefix(Data("❯ Try it".utf8))
        XCTAssertEqual(text, "❯ Try it")
        XCTAssertTrue(rest.isEmpty)
    }

    func testSplitMultiByteSequenceIsCarriedToTheNextChunk() {
        // "❯" is E2 9D AF; a read boundary after the first byte must not drop
        // the text before it or the two bytes still to come.
        let bytes = Data("Session held ".utf8) + Data([0xE2])
        let (text, rest) = PTYAdapterBase.decodeUTF8Prefix(bytes)
        XCTAssertEqual(text, "Session held ")
        XCTAssertEqual(rest, Data([0xE2]))

        let (next, nextRest) = PTYAdapterBase.decodeUTF8Prefix(rest + Data([0x9D, 0xAF]) + Data(" done".utf8))
        XCTAssertEqual(next, "❯ done")
        XCTAssertTrue(nextRest.isEmpty)
    }

    func testBytesThatCanNeverDecodeAreReplacedNotDropped() {
        let (text, rest) = PTYAdapterBase.decodeUTF8Prefix(Data("ok ".utf8) + Data([0xFF, 0xFE]) + Data(" still here".utf8))
        XCTAssertTrue(text.hasPrefix("ok "))
        XCTAssertTrue(text.hasSuffix(" still here"))
        XCTAssertTrue(rest.isEmpty)
    }
}
