import SwiftUI
import GTProtocol
import GTSecurity
import GTAdapters

#if os(macOS)
import AppKit

@main
struct GlassTunnelAppEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // A menu bar extra that is never inserted gives the SwiftUI runtime a
    // scene to host and the app menu commands to hang on, and has no window.
    // (A placeholder Settings scene opened an empty window at launch once the
    // app was built with the macOS 27 SDK.) The main window (NSHostingView)
    // and the menu bar icon (MenuBarController) are created imperatively in
    // AppDelegate - this sidesteps the MenuBarExtra + WindowGroup interaction
    // where SwiftUI refuses to auto-open a window.
    var body: some Scene {
        MenuBarExtra("Glasstunnel", isInserted: .constant(false)) {
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var appState: AppState?
    private var mainWindow: NSWindow?
    private var menuBar: MenuBarController?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            // Starts Sparkle's daily check in release builds.
            _ = AppUpdater.shared
            createMainWindow()
            createMenuBar()
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
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            appState = nil
        }
    }

    // The host keeps serving phones from the menu bar after the window closes.
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        BackgroundPresencePolicy.quitsWhenWindowCloses
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = NSApp.setActivationPolicy(BackgroundPresencePolicy.activationPolicy(mainWindowOpen: false))
        }
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
        window.delegate = self
        AppWindowPresentationPolicy.configureMainWindow(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.mainWindow = window
    }

    private func createMenuBar() {
        guard let appState else { return }
        menuBar = MenuBarController(appState: appState) { [weak self] tab in
            self?.showMainWindow(tab: tab)
        }
    }

    func showSettings() {
        showMainWindow(tab: .settings)
    }

    func showMainWindow(tab: AppNavigationTab) {
        appState?.selectTab(tab)
        ensureMainWindowVisible()
    }

    private func ensureMainWindowVisible() {
        NSApp.setActivationPolicy(BackgroundPresencePolicy.activationPolicy(mainWindowOpen: true))
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
