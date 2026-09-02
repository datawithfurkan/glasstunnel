#if os(macOS)
import SwiftUI
import GTProtocol
import GTTransport

struct WorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    private var filteredApps: [RemoteApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.remoteApps }
        return appState.remoteApps.filter { app in
            app.displayName.lowercased().contains(query)
                || app.windowTitle.lowercased().contains(query)
                || app.statusDetail.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                searchField
                remoteAppsList
                .padding(.bottom, 24)
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(GlasstunnelDesign.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                GlasstunnelPageHeading(
                    title: "Workspace",
                    subtitle: "Apps available for remote use from your browser."
                )
            }

            Spacer()

            if !appState.isLinkedToAccount {
                Button {
                    appState.selectTab(.access)
                } label: {
                    Label("Sign in & link Mac", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .pointingHandCursor()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(GlasstunnelDesign.muted)
            TextField("Search apps", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .fill(GlasstunnelDesign.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .stroke(GlasstunnelDesign.border, lineWidth: 1)
        )
    }

    private var remoteAppsList: some View {
        GlasstunnelGroupedList {
            GlasstunnelGroupHeader(
                title: "Apps",
                subtitle: "\(appState.remoteApps.filter(\.available).count) of \(appState.remoteApps.count) available"
            )
            GlasstunnelRowDivider(leadingInset: 0)

            if filteredApps.isEmpty {
                GlasstunnelListRow(
                    title: "No matching apps",
                    subtitle: "Try another search.",
                    systemImage: "magnifyingglass",
                    iconColor: GlasstunnelDesign.muted
                ) {
                    EmptyView()
                }
            } else {
                ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 {
                        GlasstunnelRowDivider()
                    }
                    RemoteAppRow(app: app)
                }
            }
        }
    }
}

private struct RemoteAppRow: View {
    @EnvironmentObject var appState: AppState
    let app: RemoteApp

    private var definition: RemoteAppDefinition? {
        RemoteAppDefinition.definition(for: app.remoteAppId)
    }

    private var windowOptions: [RemoteAppWindowOption] {
        appState.windowOptions(for: app.remoteAppId)
    }

    private var presentation: RemoteAppRowPresentation {
        RemoteAppRowPresentation(app: app, openHint: definition?.openHint)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconTile(app: app, symbolName: definition?.symbolName ?? "terminal")

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text(primaryDetail)
                    .font(.caption)
                    .foregroundStyle(app.available ? GlasstunnelDesign.muted : GlasstunnelDesign.warning)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            if windowOptions.count > 1 {
                Menu {
                    ForEach(windowOptions) { option in
                        Button {
                            appState.selectRemoteAppWindow(
                                remoteAppId: app.remoteAppId,
                                windowKey: option.windowKey
                            )
                        } label: {
                            Text(option.title)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointingHandCursor()
                .help("Change window")
            }

            if presentation.hasToggle {
                Toggle(presentation.controlLabelText, isOn: remoteAppToggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help(presentation.controlLabelText)
            } else {
                GlasstunnelStatusLabel(
                    title: statusLabel,
                    systemImage: statusIcon,
                    color: statusColor
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var remoteAppToggleBinding: Binding<Bool> {
        Binding(
            get: { app.enabled },
            set: { enabled in
                appState.setRemoteAppEnabled(app.remoteAppId, enabled: enabled)
            }
        )
    }

    private var primaryDetail: String {
        presentation.primaryDetail
    }

    private var statusLabel: String {
        if !app.enabled { return "Off" }
        if !app.available { return "Not ready" }
        switch app.status {
        case .working: return "Syncing"
        case .error: return "Needs attention"
        case .disconnected: return "Offline"
        default: return "Ready"
        }
    }

    private var statusIcon: String {
        if !app.enabled { return "circle" }
        if !app.available { return "exclamationmark.circle" }
        switch app.status {
        case .working: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        case .disconnected: return "wifi.slash"
        default: return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        if !app.enabled { return GlasstunnelDesign.muted }
        if !app.available { return GlasstunnelDesign.warning }
        switch app.status {
        case .working: return GlasstunnelDesign.accent
        case .error: return GlasstunnelDesign.danger
        case .disconnected: return GlasstunnelDesign.warning
        default: return GlasstunnelDesign.success
        }
    }
}

struct RemoteAppRowPresentation: Equatable {
    enum Tone {
        case warning
        case accent
        case success
        case muted
    }

    let app: RemoteApp
    let openHint: String?

    var hasToggle: Bool {
        app.remoteAppId == "screen" || app.remoteAppId == "terminal"
    }

    var primaryDetail: String {
        if app.remoteAppId == "screen", app.enabled, !app.available {
            return unavailableDetailText
        }
        if app.remoteAppId == "screen", !app.enabled {
            return "Screen sharing off"
        }
        if app.remoteAppId == "terminal", !app.enabled {
            return "Open Terminal to start remote access"
        }
        if app.remoteAppId == "terminal", app.enabled, app.status == .working {
            return statusDetailText
        }
        if app.windowTitle.isEmpty {
            if app.remoteAppId == "screen" {
                return "Ready for screen sharing"
            }
            if app.remoteAppId == "terminal" {
                return app.available ? "Ready for terminal access" : unavailableDetailText
            }
            return app.available ? "Ready from web" : (openHint ?? "App not open")
        }
        return app.windowTitle
    }

    var statusDetailText: String {
        if app.remoteAppId == "screen", !app.enabled {
            return "Screen sharing off"
        }
        let detail = app.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail.localizedCaseInsensitiveContains("enable") {
            return app.remoteAppId == "screen" ? "Screen ready" : "Ready from web"
        }
        return detail
    }

    var unavailableDetailText: String {
        let detail = app.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? (openHint ?? "Open this app on your Mac") : detail
    }

    var controlLabelText: String {
        app.remoteAppId == "terminal" ? "Open Terminal" : "Screen sharing"
    }

    var controlStatusText: String {
        if app.remoteAppId == "terminal" {
            if app.enabled, !app.available { return "Needs shell" }
            if app.status == .working { return "Opening" }
            return app.enabled ? "Terminal ready" : "Closed"
        }
        if app.enabled, !app.available {
            return "Needs access"
        }
        return app.enabled ? "Sharing on" : "Sharing off"
    }

    var controlTone: Tone {
        if app.enabled, !app.available {
            return .warning
        }
        if app.status == .working {
            return .accent
        }
        return app.enabled ? .success : .muted
    }
}

private struct AppIconTile: View {
    let app: RemoteApp
    let symbolName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .fill(iconColor.opacity(app.available ? 0.18 : 0.10))
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 36, height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .stroke(iconColor.opacity(app.available ? 0.36 : 0.18), lineWidth: 1)
        )
    }

    private var iconColor: Color {
        switch app.remoteAppId {
        case "codex": return GlasstunnelDesign.accent
        case "cursor": return Color(red: 0.75, green: 0.76, blue: 0.78)
        case "claude-desktop", "claude-code": return Color(red: 0.93, green: 0.58, blue: 0.34)
        case "codex-cli": return Color(red: 0.38, green: 0.76, blue: 1.0)
        case "opencode": return Color(red: 0.58, green: 0.88, blue: 0.68)
        default: return GlasstunnelDesign.accent
        }
    }
}
#endif
