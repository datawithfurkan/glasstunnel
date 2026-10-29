#if os(macOS)
import SwiftUI

enum MenuBarContentPolicy {
    static let quitTitle = "Quit Glasstunnel"
    static let backgroundNote = "Closing the window keeps Glasstunnel running here, so your phone stays connected. Quit to go offline."

    static let normalPathText = [
        "Glasstunnel",
        "Screen Recording",
        "Accessibility",
        "Open Workspace",
        "Open Web App",
        "Open Access",
        "Read-only mode",
        "Keep Mac awake",
        "Refresh",
        AppUpdater.menuTitle,
        backgroundNote,
        quitTitle,
    ]

    /// "Online", or "Online · iPhone connected" while phones are connected.
    static func statusLine(hostStatus: String, connectedDeviceLabels: [String]) -> String {
        switch connectedDeviceLabels.count {
        case 0: return hostStatus
        case 1: return "\(hostStatus) · \(connectedDeviceLabels[0]) connected"
        default: return "\(hostStatus) · \(connectedDeviceLabels.count) devices connected"
        }
    }

    static func accessDeviceSummary(count: Int) -> String {
        switch count {
        case 0: return "No access devices"
        case 1: return "1 access device"
        default: return "\(count) access devices"
        }
    }
}

/// The popover under the menu bar icon. `MenuBarController` hosts it.
struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var updater: AppUpdater = .shared
    let openWindow: (AppNavigationTab) -> Void
    let closeMenu: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                BrandMarkView(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Glasstunnel").font(.headline)
                    HStack(spacing: 4) {
                        Circle().fill(hostStatusColor).frame(width: 7, height: 7)
                        Text(MenuBarContentPolicy.statusLine(
                            hostStatus: appState.hostStatusLabel,
                            connectedDeviceLabels: appState.connectedDevices.map(\.label)
                        ))
                        .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(AppVersionInfo.current().version)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            HStack {
                statusDot(appState.screenRecordingGranted, label: "Screen Recording")
                Spacer()
                statusDot(appState.accessibilityGranted, label: "Accessibility")
            }
            .font(.caption)

            Divider()

            actionRow("Open Workspace", systemImage: "macwindow") {
                openWindow(.workspace)
            }

            actionRow("Open Web App", systemImage: "iphone") {
                closeMenu()
                NSWorkspace.shared.open(appState.webAppURL)
            }
            .help("Open \(PhoneAccessContent.displayAddress(for: appState.webAppURL)), where your phone signs in")

            actionRow("Open Access", systemImage: AppNavigationTab.access.systemImage) {
                openWindow(.access)
            }

            toggleRow("Read-only mode", systemImage: "lock", isOn: $appState.isReadOnly)
            toggleRow("Keep Mac awake", systemImage: "power", isOn: $appState.keepAwakeEnabled)

            Divider()

            HStack {
                Text(MenuBarContentPolicy.accessDeviceSummary(count: appState.trustedDeviceCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { appState.refreshPairedDevices() }
                    .controlSize(.small)
                    .pointingHandCursor()
            }

            Divider()

            actionRow(updater.checkTitle, systemImage: "arrow.triangle.2.circlepath") {
                closeMenu()
                updater.checkForUpdates()
            }
            .disabled(!updater.checkIsAvailable)

            Divider()

            Text(MenuBarContentPolicy.backgroundNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(MenuBarContentPolicy.quitTitle) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .pointingHandCursor()
        }
        .padding(12)
        .frame(width: 300)
        .tint(GlasstunnelDesign.accent)
    }

    private var hostStatusColor: Color {
        switch appState.sessionManagerState {
        case "connected": return GlasstunnelDesign.success
        case "connecting", "error": return GlasstunnelDesign.warning
        default: return GlasstunnelDesign.muted
        }
    }

    /// Icons share one width so the row titles line up.
    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 18)
        }
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack {
            rowLabel(title, systemImage: systemImage)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointingHandCursor()
        }
    }

    @ViewBuilder
    private func statusDot(_ ok: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? .green : .red).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
#endif
