#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import GTProtocol
import GTSecurity

struct SettingsContentPolicy {
    static let normalPathText = [
        "Settings",
        "Manage how Glasstunnel works on this Mac.",
        "General",
        "Launch at Login",
        "Keep Mac awake",
        "Auto-lock timeout",
        "Security",
        "Read-only mode",
        "Permissions",
        "Updates",
        "Installed version",
        "Check for Updates",
        "Advanced",
    ]

    static let internalConnectivityTerms = [
        "Web app URL",
        "Signaling",
        "TURN",
        "Host device ID",
        "Protocol version",
        "Session state",
        "input injection",
    ]
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var signalingURLString: String = ""
    @State private var webAppURLString: String = ""
    @State private var turnURLString: String = ""
    @State private var turnUsername: String = ""
    @State private var turnPassword: String = ""
    @State private var customRedactionPatterns: String = ""
    @State private var showAdvancedSettings = false
    @State private var diagnosticsCopyFeedback: DiagnosticsCopyFeedback?
    @State private var updateActionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlasstunnelPageHeading(
                    title: "Settings",
                    subtitle: "Manage how Glasstunnel works on this Mac."
                )

                primarySettings
                advancedSettings
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
    }

    private var primarySettings: some View {
        GlasstunnelGroupedList {
            GlasstunnelGroupHeader(title: "General")
            GlasstunnelRowDivider(leadingInset: 0)

            LaunchAtLoginSetting(controller: appState.launchAtLogin)
            GlasstunnelRowDivider()

            GlasstunnelListRow(
                title: "Keep Mac Awake",
                subtitle: "Keep this Mac available while Glasstunnel is running.",
                systemImage: "moon",
                iconColor: GlasstunnelDesign.accent
            ) {
                Toggle("Keep Mac Awake", isOn: $appState.keepAwakeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointingHandCursor()
            }
            GlasstunnelRowDivider()

            GlasstunnelListRow(
                title: "Auto-lock timeout",
                subtitle: "Locks remote access after inactivity.",
                systemImage: "lock",
                iconColor: GlasstunnelDesign.muted
            ) {
                Text("\(Int(appState.autoLock.idleTimeout / 60)) minutes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GlasstunnelDesign.muted)
            }

            GlasstunnelRowDivider(leadingInset: 0)
            GlasstunnelGroupHeader(title: "Security")
            GlasstunnelRowDivider(leadingInset: 0)

            GlasstunnelListRow(
                title: "Read-only mode",
                subtitle: "Prevent connected devices from making changes.",
                systemImage: "shield",
                iconColor: GlasstunnelDesign.accent
            ) {
                Toggle("Read-only mode", isOn: $appState.isReadOnly)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .pointingHandCursor()
            }
            GlasstunnelRowDivider()

            GlasstunnelListRow(
                title: "Permissions",
                subtitle: "Screen Recording and Accessibility access.",
                systemImage: "key",
                iconColor: permissionsColor
            ) {
                GlasstunnelStatusLabel(
                    title: permissionSummary,
                    systemImage: permissionsSystemImage,
                    color: permissionsColor
                )
            }

            GlasstunnelRowDivider(leadingInset: 0)
            GlasstunnelGroupHeader(title: "Updates")
            GlasstunnelRowDivider(leadingInset: 0)

            GlasstunnelListRow(
                title: "Installed version",
                subtitle: AppVersionInfo.current().displayValue,
                systemImage: "arrow.triangle.2.circlepath",
                iconColor: GlasstunnelDesign.accent
            ) {
                Button("Check for Updates") {
                    updateActionError = NSWorkspace.shared.open(AppVersionInfo.releasesURL)
                        ? nil
                        : "Could not open the Glasstunnel Releases page."
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }

            if let updateActionError {
                Text(updateActionError)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.danger)
                    .padding(.horizontal, 64)
                    .padding(.bottom, 12)
            }
        }
    }

    private var advancedSettings: some View {
        GlasstunnelGroupedList {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showAdvancedSettings.toggle()
                }
            } label: {
                GlasstunnelListRow(
                    title: "Advanced",
                    subtitle: "Connectivity, diagnostics, and secret filtering.",
                    systemImage: "gearshape.2",
                    iconColor: GlasstunnelDesign.muted
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(GlasstunnelDesign.muted)
                        .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if showAdvancedSettings {
                GlasstunnelRowDivider(leadingInset: 0)
                advancedContent
            }
        }
    }

    private var advancedContent: some View {
        VStack(spacing: 0) {
            GlasstunnelGroupHeader(title: "Connectivity", subtitle: "Hosted app, signaling, and TURN")

            VStack(spacing: 14) {
                settingsField("Web app URL", text: $webAppURLString)
                    .onAppear { webAppURLString = appState.webAppURL.absoluteString }
                    .onChange(of: webAppURLString) { newValue in
                        if let url = URL(string: newValue) { appState.webAppURL = url }
                    }

                settingsField("Signaling URL", text: $signalingURLString)
                    .onAppear { signalingURLString = appState.signalingURL.absoluteString }
                    .onChange(of: signalingURLString) { newValue in
                        if let url = URL(string: newValue) { appState.signalingURL = url }
                    }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 14) {
                    settingsField("TURN URL", text: $turnURLString)
                        .onAppear { turnURLString = appState.turnURL }
                        .onChange(of: turnURLString) { appState.turnURL = $0 }

                    settingsField("TURN username", text: $turnUsername)
                        .onAppear { turnUsername = appState.turnUsername }
                        .onChange(of: turnUsername) { appState.turnUsername = $0 }

                    secureSettingsField("TURN password", text: $turnPassword)
                        .onAppear { turnPassword = appState.turnPassword }
                        .onChange(of: turnPassword) { appState.turnPassword = $0 }
                }

                Text("TURN is optional. Leave it empty for same-network access.")
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            GlasstunnelRowDivider(leadingInset: 0)
            diagnosticsSection
            GlasstunnelRowDivider(leadingInset: 0)
            redactionSection
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlasstunnelGroupHeader(title: "Diagnostics", subtitle: "Privacy-safe build and host metadata")

            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow("App", value: AppVersionInfo.current().displayValue)
                diagnosticRow("macOS", value: currentMacOSVersion)
                diagnosticRow("Protocol version", value: GlasstunnelProtocol.version)
                diagnosticRow("Screen Recording", value: permissionValue(granted: appState.screenRecordingGranted))
                diagnosticRow("Accessibility", value: permissionValue(granted: appState.accessibilityGranted))
                diagnosticRow("Connection", value: DiagnosticsConnectionState(sessionManagerState: appState.sessionManagerState).rawValue)
                diagnosticRow("Account", value: appState.isLinkedToAccount ? "Linked" : "Not linked")

                Button {
                    copyDiagnostics()
                } label: {
                    Label(
                        diagnosticsCopyFeedback == .success ? "Copied" : "Copy Diagnostics",
                        systemImage: diagnosticsCopyFeedback == .success ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()

                if let diagnosticsCopyFeedback {
                    Text(diagnosticsCopyFeedback.message)
                        .font(.caption)
                        .foregroundStyle(
                            diagnosticsCopyFeedback == .success
                                ? GlasstunnelDesign.success
                                : GlasstunnelDesign.danger
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var redactionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlasstunnelGroupHeader(
                title: "Secret filtering",
                subtitle: "\(SecretRedactor.defaultPatterns.count) built-in patterns active"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom patterns (one regex per line)")
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
                TextEditor(text: $customRedactionPatterns)
                    .frame(height: 120)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                            .fill(GlasstunnelDesign.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                            .stroke(GlasstunnelDesign.border, lineWidth: 1)
                    )
                    .onChange(of: customRedactionPatterns) { newValue in
                        let lines = newValue.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                        let patterns = lines.enumerated().map { index, pattern in
                            SecretRedactor.Pattern(name: "user_\(index)", regex: pattern)
                        }
                        appState.redactor.setPatterns(SecretRedactor.defaultPatterns + patterns)
                    }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var permissionSummary: String {
        guard appState.permissionsChecked else { return "Checking" }
        return appState.requiredPermissionsGranted ? "Allowed" : "Needs access"
    }

    private var permissionsColor: Color {
        guard appState.permissionsChecked else { return GlasstunnelDesign.muted }
        return appState.requiredPermissionsGranted ? GlasstunnelDesign.success : GlasstunnelDesign.warning
    }

    private var permissionsSystemImage: String {
        guard appState.permissionsChecked else { return "clock" }
        return appState.requiredPermissionsGranted ? "checkmark.circle" : "exclamationmark.circle"
    }

    private func settingsField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(GlasstunnelDesign.muted)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                        .fill(GlasstunnelDesign.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                        .stroke(GlasstunnelDesign.border, lineWidth: 1)
                )
        }
    }

    private func secureSettingsField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(GlasstunnelDesign.muted)
            SecureField(title, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                        .fill(GlasstunnelDesign.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                        .stroke(GlasstunnelDesign.border, lineWidth: 1)
                )
        }
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(GlasstunnelDesign.muted)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private var currentMacOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func permissionValue(granted: Bool) -> String {
        guard appState.permissionsChecked else { return DiagnosticsPermissionStatus.notChecked.rawValue }
        return granted
            ? DiagnosticsPermissionStatus.allowed.rawValue
            : DiagnosticsPermissionStatus.needsAccess.rawValue
    }

    private func copyDiagnostics() {
        let input = DiagnosticsReportBuilder.currentInput(
            permissionsChecked: appState.permissionsChecked,
            screenRecordingGranted: appState.screenRecordingGranted,
            accessibilityGranted: appState.accessibilityGranted,
            sessionManagerState: appState.sessionManagerState,
            accountLinked: appState.isLinkedToAccount
        )
        let report = DiagnosticsReportBuilder.build(input)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let result: DiagnosticsCopyFeedback = pasteboard.setString(report, forType: .string) ? .success : .failure
        diagnosticsCopyFeedback = result
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if diagnosticsCopyFeedback == result {
                diagnosticsCopyFeedback = nil
            }
        }
    }
}

private enum DiagnosticsCopyFeedback: Equatable {
    case success
    case failure

    var message: String {
        switch self {
        case .success: return "Diagnostics copied."
        case .failure: return "Could not copy diagnostics."
        }
    }
}

private struct LaunchAtLoginSetting: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlasstunnelListRow(
                title: "Launch at Login",
                subtitle: "Open Glasstunnel after you sign in to this Mac.",
                systemImage: "power",
                iconColor: GlasstunnelDesign.accent
            ) {
                HStack(spacing: 10) {
                    if controller.isUpdating {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Toggle(
                        "Launch at Login",
                        isOn: Binding(
                            get: { controller.isEnabled },
                            set: { controller.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(controller.isUpdating)
                    .pointingHandCursor(!controller.isUpdating)
                }
            }

            if let feedback = controller.feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(
                        feedback.tone == .error
                            ? GlasstunnelDesign.danger
                            : GlasstunnelDesign.warning
                    )
                    .padding(.leading, 64)
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
            }
        }
        .onAppear { controller.refresh() }
    }
}
#endif
