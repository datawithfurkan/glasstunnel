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
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: AppUpdater.shared)
            }
            // Settings live in the main window, not in the placeholder scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button(AppUpdater.menuTitle) {
            updater.checkForUpdates()
        }
        .disabled(!updater.checkIsAvailable)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var mainWindow: NSWindow?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            // Starts Sparkle's daily check in release builds.
            _ = AppUpdater.shared
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
            appState?.launchAtLogin.refresh()
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

    func showSettings() {
        appState?.selectTab(.settings)
        ensureMainWindowVisible()
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
