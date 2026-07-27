#if os(macOS)
import SwiftUI
import GTProtocol

struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrandMarkView(size: 18)
                Text("Glasstunnel").font(.headline)
                Spacer()
                Text("v\(GlasstunnelProtocol.version)")
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

            Button {
                openMainWindow()
            } label: {
                Label("Open Workspace", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button {
                openMainWindow(tab: .access)
            } label: {
                Label("Open Access", systemImage: AppNavigationTab.access.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Toggle(isOn: $appState.isReadOnly) {
                Label("Read-only mode", systemImage: "lock")
            }
            .toggleStyle(.switch)
            .pointingHandCursor()

            Toggle(isOn: $appState.keepAwakeEnabled) {
                Label("Keep Mac awake", systemImage: "power")
            }
            .toggleStyle(.switch)
            .pointingHandCursor()

            Divider()

            HStack {
                Text("\(appState.trustedDeviceCount) access device(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { appState.refreshPairedDevices() }
                    .controlSize(.small)
                    .pointingHandCursor()
            }

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .pointingHandCursor()
        }
        .padding(12)
    }

    @ViewBuilder
    private func statusDot(_ ok: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? .green : .red).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func openMainWindow(tab: AppNavigationTab = .workspace) {
        appState.selectTab(tab)
        if let window = NSApp.windows.first(where: { $0.title == "Glasstunnel" }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
