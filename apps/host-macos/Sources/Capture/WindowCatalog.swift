#if os(macOS)
import AppKit
import Foundation
import ScreenCaptureKit

/// A lightweight description of a capturable window. The host UI uses this
/// to present a live thumbnail grid the user can drag from.
public struct CapturableWindow: Sendable, Hashable, Identifiable {
    public var id: CGWindowID { windowID }
    public let windowID: CGWindowID
    public let title: String
    public let applicationName: String
    public let applicationBundleID: String
    public let pid: pid_t
    public let frame: CGRect
    public let isOnScreen: Bool

    public init(windowID: CGWindowID, title: String, applicationName: String, applicationBundleID: String, pid: pid_t, frame: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.title = title
        self.applicationName = applicationName
        self.applicationBundleID = applicationBundleID
        self.pid = pid
        self.frame = frame
        self.isOnScreen = isOnScreen
    }

    public static func == (lhs: CapturableWindow, rhs: CapturableWindow) -> Bool {
        lhs.windowID == rhs.windowID &&
            lhs.title == rhs.title &&
            lhs.applicationName == rhs.applicationName &&
            lhs.applicationBundleID == rhs.applicationBundleID &&
            lhs.pid == rhs.pid &&
            lhs.frame.equalTo(rhs.frame) &&
            lhs.isOnScreen == rhs.isOnScreen
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(title)
        hasher.combine(applicationName)
        hasher.combine(applicationBundleID)
        hasher.combine(pid)
        hasher.combine(Double(frame.origin.x))
        hasher.combine(Double(frame.origin.y))
        hasher.combine(Double(frame.size.width))
        hasher.combine(Double(frame.size.height))
        hasher.combine(isOnScreen)
    }
}

/// Enumerates capturable windows via ScreenCaptureKit. Filters to real
/// on-screen windows owned by other processes (skips system windows).
public enum WindowCatalog {
    public static func refresh() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.current
        return content.windows.compactMap { w in
            guard w.title?.isEmpty == false else { return nil }
            guard let app = w.owningApplication else { return nil }
            return CapturableWindow(
                windowID: w.windowID,
                title: w.title ?? "",
                applicationName: app.applicationName,
                applicationBundleID: app.bundleIdentifier,
                pid: app.processID,
                frame: w.frame,
                isOnScreen: w.isOnScreen
            )
        }.sorted { a, b in
            if a.applicationName != b.applicationName {
                return a.applicationName < b.applicationName
            }
            return a.title < b.title
        }
    }

    /// Resolves a bundle ID to the first matching capturable window, if any.
    public static func firstWindow(forBundleID bundleID: String) async throws -> CapturableWindow? {
        let all = try await refresh()
        return all.first { $0.applicationBundleID == bundleID }
    }
}
#else
public struct CapturableWindow: Sendable, Hashable, Identifiable {
    public var id: UInt32 { windowID }
    public let windowID: UInt32
    public let title: String
    public let applicationName: String
    public let applicationBundleID: String
    public let pid: Int32
}
public enum WindowCatalog {
    public static func refresh() async throws -> [CapturableWindow] { [] }
}
#endif
