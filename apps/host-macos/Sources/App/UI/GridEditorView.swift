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

    private var supportedCount: Int {
        appState.remoteApps.count
    }

    private var availableCount: Int {
        appState.remoteApps.filter(\.available).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                RemoteAppsSummaryStrip(
                    supportedCount: supportedCount,
                    availableCount: availableCount,
                    sessionState: appState.sessionManagerState,
                    accountLinked: appState.isLinkedToAccount
                )

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(GlasstunnelDesign.muted)
                        TextField("Search remote apps", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(GlasstunnelDesign.surfaceAlt.opacity(0.42))
                    )

                    VStack(spacing: 10) {
                        ForEach(filteredApps) { app in
                            RemoteAppRow(app: app)
                        }
                    }
                }
                .glasstunnelPanelStyle(radius: 18)
                .padding(.bottom, 24)
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(GlasstunnelDesign.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Remote apps")
                    .font(.system(size: 34, weight: .semibold))
                Text("Start apps from the web. Glasstunnel opens and syncs them here when needed.")
                    .font(.system(size: 15))
                    .foregroundStyle(GlasstunnelDesign.muted)
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
}

private struct RemoteAppsSummaryStrip: View {
    let supportedCount: Int
    let availableCount: Int
    let sessionState: String
    let accountLinked: Bool

    private var signalingOnline: Bool { sessionState == "connected" }
    private var reconnecting: Bool { sessionState == "connecting" || sessionState == "error" }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            SummaryBadge(
                title: "\(supportedCount)",
                label: "Remote actions",
                systemImage: "square.grid.2x2",
                tone: supportedCount > 0 ? .accent : .neutral
            )
            SummaryBadge(
                title: "\(availableCount)",
                label: "Detected",
                systemImage: "app.connected.to.app.below.fill",
                tone: availableCount > 0 ? .success : .warning
            )
            SummaryBadge(
                title: signalingOnline ? "Online" : (reconnecting ? "Reconnecting" : "Offline"),
                label: signalingOnline ? "Ready for browser access" : "Restoring signaling",
                systemImage: "dot.radiowaves.left.and.right",
                tone: signalingOnline ? .success : .warning
            )
            SummaryBadge(
                title: accountLinked ? "Linked" : "Unlinked",
                label: accountLinked ? "Account access active" : "Set up in Access",
                systemImage: "person.crop.circle",
                tone: accountLinked ? .accent : .warning
            )
        }
    }
}

private struct SummaryBadge: View {
    enum Tone {
        case accent
        case success
        case warning
        case neutral

        var color: Color {
            switch self {
            case .accent: return GlasstunnelDesign.accent
            case .success: return GlasstunnelDesign.success
            case .warning: return GlasstunnelDesign.warning
            case .neutral: return GlasstunnelDesign.muted
            }
        }
    }

    let title: String
    let label: String
    let systemImage: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tone.color.opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glasstunnelPanelStyle(radius: 16)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                AppIconTile(app: app, symbolName: definition?.symbolName ?? "terminal")

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(app.displayName)
                            .font(.system(size: 16, weight: .semibold))
                        RemoteAppStatusPill(app: app)
                    }
                    Text(primaryDetail)
                        .font(.system(size: 13))
                        .foregroundStyle(GlasstunnelDesign.muted)
                        .lineLimit(1)
                }

                Spacer()

                if presentation.hasToggle {
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle(presentation.controlLabelText, isOn: remoteAppToggleBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .pointingHandCursor()
                        Text(presentation.controlStatusText)
                            .font(.caption2)
                            .foregroundStyle(controlStatusColor(for: presentation))
                    }
                }
            }

            HStack(spacing: 10) {
                if windowOptions.count > 1 {
                    Menu {
                        ForEach(windowOptions) { option in
                            Button {
                                appState.selectRemoteAppWindow(
                                    remoteAppId: app.remoteAppId,
                                    windowKey: option.windowKey
                                )
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(option.title)
                                    Text(option.subtitle)
                                }
                            }
                        }
                    } label: {
                        Label("Change window", systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                }

                if app.available {
                    Label(statusDetailText, systemImage: syncIcon)
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.muted)
                        .lineLimit(1)
                } else if !app.available {
                    Label(unavailableDetailText, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.warning)
                }

                Spacer()
            }
            .padding(.leading, 58)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(rowIsReady ? GlasstunnelDesign.accent.opacity(0.08) : GlasstunnelDesign.surfaceAlt.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(rowIsReady ? GlasstunnelDesign.accent.opacity(0.26) : GlasstunnelDesign.border, lineWidth: 1)
        )
    }

    private var remoteAppToggleBinding: Binding<Bool> {
        Binding(
            get: { app.enabled },
            set: { enabled in
                appState.setRemoteAppEnabled(app.remoteAppId, enabled: enabled)
            }
        )
    }

    private var rowIsReady: Bool {
        app.available && app.enabled
    }

    private var primaryDetail: String {
        presentation.primaryDetail
    }

    private var statusDetailText: String {
        presentation.statusDetailText
    }

    private var unavailableDetailText: String {
        presentation.unavailableDetailText
    }

    private func controlStatusColor(for presentation: RemoteAppRowPresentation) -> Color {
        switch presentation.controlTone {
        case .warning:
            return GlasstunnelDesign.warning
        case .accent:
            return GlasstunnelDesign.accent
        case .success:
            return GlasstunnelDesign.success
        case .muted:
            return GlasstunnelDesign.muted
        }
    }

    private var syncIcon: String {
        switch app.status {
        case .working: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle"
        case .disconnected: return "wifi.slash"
        default: return "checkmark.circle"
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(iconColor.opacity(app.available ? 0.18 : 0.10))
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(iconColor.opacity(app.available ? 0.36 : 0.18), lineWidth: 1)
        )
    }

    private var iconColor: Color {
        switch app.remoteAppId {
        case "codex": return GlasstunnelDesign.accent
        case "cursor": return Color(red: 0.75, green: 0.76, blue: 0.78)
        case "claude-code": return Color(red: 0.93, green: 0.58, blue: 0.34)
        case "codex-cli": return Color(red: 0.38, green: 0.76, blue: 1.0)
        case "opencode": return Color(red: 0.58, green: 0.88, blue: 0.68)
        default: return GlasstunnelDesign.accent
        }
    }
}

private struct RemoteAppStatusPill: View {
    let app: RemoteApp

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.16))
            )
            .foregroundStyle(color)
    }

    private var label: String {
        if !app.enabled { return "Off" }
        if !app.available { return app.remoteAppId == "screen" ? "Needs access" : "Not ready" }
        switch app.status {
        case .working: return "Syncing"
        case .error: return "Needs attention"
        case .disconnected: return "Offline"
        default: return "Ready"
        }
    }

    private var color: Color {
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
#endif
