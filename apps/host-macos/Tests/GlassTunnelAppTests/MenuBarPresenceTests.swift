import AppKit
import XCTest
@testable import GlassTunnelApp

final class MenuBarPresenceTests: XCTestCase {
    func testClosingTheWindowKeepsTheHostRunning() {
        XCTAssertFalse(BackgroundPresencePolicy.quitsWhenWindowCloses)
    }

    func testDockIconAndAppMenuFollowTheMainWindow() {
        XCTAssertEqual(BackgroundPresencePolicy.activationPolicy(mainWindowOpen: true), .regular)
        XCTAssertEqual(BackgroundPresencePolicy.activationPolicy(mainWindowOpen: false), .accessory)
    }

    func testMenuBarIconDimsUntilTheHostIsOnline() {
        let online = MenuBarStatusPresentation(sessionState: "connected")
        XCTAssertTrue(online.isOnline)
        XCTAssertEqual(online.toolTip, "Glasstunnel: Online")

        for state in ["connecting", "error"] {
            let presentation = MenuBarStatusPresentation(sessionState: state)
            XCTAssertFalse(presentation.isOnline)
            XCTAssertEqual(presentation.toolTip, "Glasstunnel: Reconnecting")
        }

        let idle = MenuBarStatusPresentation(sessionState: "idle")
        XCTAssertFalse(idle.isOnline)
        XCTAssertEqual(idle.toolTip, "Glasstunnel: Offline")
    }

    @MainActor
    func testMenuBarImageIsATemplateThatDrawsTheMark() throws {
        let image = BrandMarkView.menuBarImage
        XCTAssertTrue(image.isTemplate, "The menu bar tints template images for light, dark, and highlighted states")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        var inkedColumns = Set<Int>()
        var inkedRows = Set<Int>()
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inkedColumns.insert(x)
                inkedRows.insert(y)
            }
        }
        // The strokes span most of the width and stay inside the image.
        XCTAssertGreaterThan(inkedColumns.count, 24)
        XCTAssertGreaterThan(inkedRows.count, 16)
        XCTAssertFalse(inkedColumns.contains(0) || inkedColumns.contains(35))
        XCTAssertFalse(inkedRows.contains(0) || inkedRows.contains(35))
    }

    func testMenuBarOffersUpdatesAndQuitInProductLanguage() {
        let text = MenuBarContentPolicy.normalPathText
        XCTAssertTrue(text.contains("Check for Updates…"))
        XCTAssertTrue(text.contains("Quit Glasstunnel"))

        let joined = text.joined(separator: " ")
        for internalTerm in SettingsContentPolicy.internalConnectivityTerms {
            XCTAssertFalse(
                joined.localizedCaseInsensitiveContains(internalTerm),
                "The menu bar should not expose \(internalTerm)"
            )
        }
    }

    func testStatusLineNamesConnectedPhonesWithoutInternalTerms() {
        XCTAssertEqual(MenuBarContentPolicy.statusLine(hostStatus: "Reconnecting", connectedDeviceLabels: []), "Reconnecting")
        XCTAssertEqual(
            MenuBarContentPolicy.statusLine(hostStatus: "Online", connectedDeviceLabels: ["Safari on iPhone"]),
            "Online · Safari on iPhone connected"
        )
        XCTAssertEqual(
            MenuBarContentPolicy.statusLine(hostStatus: "Online", connectedDeviceLabels: ["A", "B"]),
            "Online · 2 devices connected"
        )
    }

    func testAccessDeviceSummaryCountsDevices() {
        XCTAssertEqual(MenuBarContentPolicy.accessDeviceSummary(count: 0), "No access devices")
        XCTAssertEqual(MenuBarContentPolicy.accessDeviceSummary(count: 1), "1 access device")
        XCTAssertEqual(MenuBarContentPolicy.accessDeviceSummary(count: 3), "3 access devices")
    }
}
