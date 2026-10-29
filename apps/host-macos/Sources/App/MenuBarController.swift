#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// How Glasstunnel presents itself while the host keeps running.
///
/// Closing the main window does not stop the host, so phones stay connected.
/// The menu bar icon is then the way back, and the Dock icon and app menu stay
/// hidden until the window opens again.
enum BackgroundPresencePolicy {
    static let quitsWhenWindowCloses = false

    static func activationPolicy(mainWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        mainWindowOpen ? .regular : .accessory
    }
}

/// What the menu bar icon says about the host before its popover is opened.
struct MenuBarStatusPresentation: Equatable {
    let isOnline: Bool
    let toolTip: String

    init(sessionState: String) {
        isOnline = sessionState == "connected"
        toolTip = "Glasstunnel: \(AppState.hostStatusLabel(for: sessionState))"
    }
}

/// Owns the menu bar icon and the popover that hosts `MenuBarContent`.
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState, openWindow: @escaping (AppNavigationTab) -> Void) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let content = MenuBarContent(
            openWindow: { [weak self] tab in
                self?.closePopover()
                openWindow(tab)
            },
            closeMenu: { [weak self] in self?.closePopover() }
        )
        .environmentObject(appState)
        popover.contentViewController = NSHostingController(rootView: content)
        popover.behavior = .transient
        // The main window is always dark; the popover matches it.
        popover.appearance = NSAppearance(named: .darkAqua)

        if let button = statusItem.button {
            button.image = BrandMarkView.menuBarImage
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("Glasstunnel")
        }

        // @Published fires before the value is stored, so use the sent value.
        appState.$sessionManagerState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.showHostState(state) }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        appState.refreshPermissions()
        // Activating lets the popover take key focus and close on outside clicks.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func showHostState(_ state: String) {
        guard let button = statusItem.button else { return }
        let presentation = MenuBarStatusPresentation(sessionState: state)
        button.appearsDisabled = !presentation.isOnline
        button.toolTip = presentation.toolTip
    }
}
#endif
