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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlasstunnelPageHeading(
                    title: "Access",
                    subtitle: "Manage your account and devices that can open this Mac."
                )

                thisMacGroup
                trustedDevicesGroup
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
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

    private var thisMacGroup: some View {
        GlasstunnelGroupedList {
            GlasstunnelGroupHeader(
                title: "This Mac",
                subtitle: "Ready for signed-in devices"
            )
            GlasstunnelRowDivider(leadingInset: 0)

            GlasstunnelListRow(
                title: appState.linkedAccount?.displayName ?? "Linked account",
                subtitle: accountSummaryLine,
                systemImage: "person.crop.circle.badge.checkmark",
                iconColor: GlasstunnelDesign.success
            ) {
                Button(role: .destructive) {
                    showingSignOutConfirmation = true
                } label: {
                    Text(isPerformingAccountAction ? "Signing out..." : "Sign Out")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPerformingAccountAction)
                .pointingHandCursor(!isPerformingAccountAction)
            }

            GlasstunnelRowDivider()

            GlasstunnelListRow(
                title: "Ready for remote access",
                subtitle: "Open the web app on any signed-in device.",
                systemImage: "checkmark.seal.fill",
                iconColor: GlasstunnelDesign.success
            ) {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(appState.webAppURL)
                    } label: {
                        Label("Open Web App", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()

                    Button {
                        copyToClipboard(appState.webAppURL.absoluteString)
                        copiedWebAppURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedWebAppURL = false
                        }
                    } label: {
                        Image(systemName: copiedWebAppURL ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .help(copiedWebAppURL ? "Copied" : "Copy web app URL")
                }
            }

            if let accessError {
                Text(accessError)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.danger)
                    .padding(.horizontal, 64)
                    .padding(.bottom, 12)
            }
        }
    }

    private var accountSummaryLine: String {
        guard let linkedAccount = appState.linkedAccount else {
            return "Signed-in devices on this account can open this Mac."
        }
        return linkedAccount.email.isEmpty ? linkedAccount.displayName : linkedAccount.email
    }

    private var trustedDevicesGroup: some View {
        GlasstunnelGroupedList {
            GlasstunnelGroupHeader(
                title: "Devices",
                subtitle: "Phones and browsers that have opened this Mac"
            )
            GlasstunnelRowDivider(leadingInset: 0)

            if appState.pairedDevices.isEmpty {
                GlasstunnelListRow(
                    title: "No access devices yet",
                    subtitle: "Open the web app from another signed-in device.",
                    systemImage: "iphone.slash",
                    iconColor: GlasstunnelDesign.muted
                ) {
                    EmptyView()
                }
            } else {
                ForEach(Array(appState.pairedDevices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 {
                        GlasstunnelRowDivider()
                    }
                    trustedDeviceRow(device)
                }
            }
        }
    }

    private func trustedDeviceRow(_ device: DeviceRegistry.PairedDevice) -> some View {
        GlasstunnelListRow(
            title: device.label.isEmpty ? "Unknown device" : device.label,
            subtitle: deviceMetadata(device),
            systemImage: device.revoked ? "xmark.circle" : "iphone",
            iconColor: device.revoked ? GlasstunnelDesign.danger : GlasstunnelDesign.accent
        ) {
            HStack(spacing: 10) {
                if device.revoked {
                    GlasstunnelStatusLabel(
                        title: "Revoked",
                        systemImage: "xmark.circle",
                        color: GlasstunnelDesign.danger
                    )
                }

                Menu {
                    if !device.revoked {
                        Button("Revoke Access", role: .destructive) {
                            appState.revokeDevice(device.deviceId)
                        }
                    }
                    Button("Remove Device", role: .destructive) {
                        appState.removeDevice(device.deviceId)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointingHandCursor()
                .help("Device actions")
            }
        }
    }

    private func deviceMetadata(_ device: DeviceRegistry.PairedDevice) -> String {
        var parts = ["Added \(device.pairedAt.formatted(.relative(presentation: .named)))"]
        if let lastSeenAt = device.lastSeenAt {
            parts.append("Last seen \(lastSeenAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
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
#endif
