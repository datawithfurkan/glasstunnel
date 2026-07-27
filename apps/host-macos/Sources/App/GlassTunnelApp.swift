import SwiftUI
import GTProtocol
import GTSecurity
import GTAdapters

#if os(macOS)
import AppKit

@main
struct GlassTunnelAppEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Settings scene acts as a harmless placeholder so the SwiftUI runtime
    // has something to host. The main window is created imperatively in
    // AppDelegate via NSHostingView - this sidesteps the MenuBarExtra +
    // WindowGroup interaction where SwiftUI refuses to auto-open a window.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var mainWindow: NSWindow?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            createMainWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag {
                ensureMainWindowVisible()
            }
        }
        return true
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            appState?.refreshPermissions()
            ensureMainWindowVisible()
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            appState = nil
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createMainWindow() {
        let state = appState ?? AppState()
        appState = state

        let contentView = MainWindow()
            .environmentObject(state)
            .frame(minWidth: 900, minHeight: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Glasstunnel"
        window.center()
        window.setFrameAutosaveName("GlasstunnelMain")
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        AppWindowPresentationPolicy.configureMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.mainWindow = window
    }

    private func ensureMainWindowVisible() {
        if let window = mainWindow {
            AppWindowPresentationPolicy.configureMainWindow(window)
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        } else {
            createMainWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum AppWindowPresentationPolicy {
    static func configureMainWindow(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

#else
@main
struct GlassTunnelAppEntry {
    static func main() {
        print("Glasstunnel Mac host requires macOS 13+. This build target runs only for library test verification.")
    }
}
#endif
