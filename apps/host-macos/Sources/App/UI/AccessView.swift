#if os(macOS)
import SwiftUI
import GTSecurity
import AppKit

struct AccessView: View {
    @EnvironmentObject var appState: AppState
    @State private var accessError: String? = nil
    @State private var isPerformingAccountAction = false
    @State private var copiedWebAppURL = false
    @State private var showingSignOutConfirmation = false
    @State private var connectionDetailsExpanded = false

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width - 48, 1080)
            let compact = contentWidth < 940

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Access")
                            .font(.system(size: 30, weight: .semibold))
                        Text("This Mac is linked to your Glasstunnel account.")
                            .font(.subheadline)
                            .foregroundStyle(GlasstunnelDesign.muted)
                    }

                    if compact {
                        VStack(alignment: .leading, spacing: 18) {
                            thisMacCard
                            openFromWebCard
                        }
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            thisMacCard
                            openFromWebCard
                        }
                    }

                    trustedDevicesCard
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(GlasstunnelDesign.background)
            .confirmationDialog("Sign out of this Mac?", isPresented: $showingSignOutConfirmation) {
                Button("Sign Out", role: .destructive) {
                    Task { await signOutLinkedAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This unlinks the Mac from your account and clears all access devices on this Mac.")
            }
        }
    }

    private var thisMacCard: some View {
        AccessCard(
            title: "Linked account",
            subtitle: "Signed-in devices can open this Mac"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                            .fill(GlasstunnelDesign.success.opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(GlasstunnelDesign.success)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.linkedAccount?.displayName ?? "Linked")
                            .font(.headline)
                        Text(accountSummaryLine)
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                Button(role: .destructive) {
                    showingSignOutConfirmation = true
                } label: {
                    Label(
                        isPerformingAccountAction ? "Signing out..." : "Sign Out",
                        systemImage: "arrow.left.circle"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isPerformingAccountAction)
                .pointingHandCursor(!isPerformingAccountAction)

                DisclosureGroup(isExpanded: $connectionDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Host", value: appState.hostDisplayName)
                        infoRow("Host device ID", value: appState.hostDeviceID() ?? "-")
                        infoRow("Web app", value: appState.webAppURL.absoluteString)
                        infoRow("Signaling", value: appState.signalingURL.absoluteString)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Details")
                        .pointingHandCursor()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(GlasstunnelDesign.muted)

                if let accessError {
                    Text(accessError)
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.danger)
                }
            }
        }
    }

    private var openFromWebCard: some View {
        AccessCard(title: "Open from web", subtitle: "Use this on any signed-in device") {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                        .fill(GlasstunnelDesign.success.opacity(0.10))
                        .frame(height: 160)
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(GlasstunnelDesign.success)
                        Text("Ready for remote access")
                            .font(.headline)
                        Text("No approval step is needed.")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                        .stroke(GlasstunnelDesign.success.opacity(0.30), lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(appState.webAppURL)
                    } label: {
                        Label("Open Web App", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()

                    Button {
                        copyToClipboard(appState.webAppURL.absoluteString)
                        copiedWebAppURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedWebAppURL = false
                        }
                    } label: {
                        Label(copiedWebAppURL ? "Copied" : "Copy URL", systemImage: copiedWebAppURL ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var accountSummaryLine: String {
        guard let linkedAccount = appState.linkedAccount else {
            return "Signed-in devices on this account can open this Mac."
        }
        return linkedAccount.email.isEmpty ? linkedAccount.displayName : linkedAccount.email
    }

    private var trustedDevicesCard: some View {
        AccessCard(title: "Devices", subtitle: "Phones and browsers that have opened this Mac") {
            if appState.pairedDevices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(GlasstunnelDesign.muted)
                    Text("No access devices yet.")
                        .foregroundStyle(GlasstunnelDesign.text)
                    Text("Open the web app from another device.")
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 12) {
                    ForEach(appState.pairedDevices) { device in
                        trustedDeviceRow(device)
                    }
                }
            }
        }
    }

    private func trustedDeviceRow(_ device: DeviceRegistry.PairedDevice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .fill(device.revoked ? GlasstunnelDesign.danger.opacity(0.10) : GlasstunnelDesign.accent.opacity(0.10))
                    .frame(width: 38, height: 38)
                Image(systemName: device.revoked ? "xmark.circle" : "iphone")
                    .foregroundStyle(device.revoked ? GlasstunnelDesign.danger : GlasstunnelDesign.accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.label.isEmpty ? "Unknown device" : device.label)
                        .font(.headline)
                    if device.revoked {
                        Text("Revoked")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                                    .fill(GlasstunnelDesign.danger.opacity(0.14))
                            )
                            .foregroundStyle(GlasstunnelDesign.danger)
                    }
                }
                HStack(spacing: 12) {
                    Text("added \(device.pairedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.muted)
                    if let lastSeenAt = device.lastSeenAt {
                        Text("last seen \(lastSeenAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                    }
                }
            }
            Spacer()
            HStack {
                if !device.revoked {
                    Button("Revoke", role: .destructive) {
                        appState.revokeDevice(device.deviceId)
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
                Button("Remove") {
                    appState.removeDevice(device.deviceId)
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                .fill(GlasstunnelDesign.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                .stroke(GlasstunnelDesign.border, lineWidth: 1)
        )
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(GlasstunnelDesign.muted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private func signOutLinkedAccount() async {
        accessError = nil
        isPerformingAccountAction = true
        defer { isPerformingAccountAction = false }
        do {
            try await appState.signOutLinkedAccount()
        } catch {
            accessError = error.localizedDescription
        }
    }
}

private struct AccessCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glasstunnelPanelStyle()
    }
}
#endif
