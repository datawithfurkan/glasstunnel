#if os(macOS)
import SwiftUI
import GTProtocol
import GTSecurity

struct SettingsContentPolicy {
    static let normalPathText = [
        "Settings",
        "Security and privacy controls for this Mac.",
        "Security",
        "Access behavior and local protection",
        "Read-only mode",
        "Keep Mac awake",
        "Auto-lock timeout",
        "Read-only mode affects all connected devices immediately.",
        "Keeps this Mac available for remote sessions while Glasstunnel is running.",
        "Redaction",
        "Built-in and custom secret filters",
        "Active default patterns",
        "Custom patterns",
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Security and privacy controls for this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(GlasstunnelDesign.muted)
                }

                SettingsCard(title: "Security", subtitle: "Access behavior and local protection") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Read-only mode", isOn: $appState.isReadOnly)
                            .pointingHandCursor()
                        Toggle("Keep Mac awake", isOn: $appState.keepAwakeEnabled)
                            .pointingHandCursor()
                        HStack {
                            Text("Auto-lock timeout")
                            Spacer()
                            Text("\(Int(appState.autoLock.idleTimeout / 60)) minutes")
                                .foregroundStyle(GlasstunnelDesign.muted)
                        }
                        Text("Read-only mode affects all connected devices immediately.")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                        Text("Keeps this Mac available for remote sessions while Glasstunnel is running.")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                    }
                }

                DisclosureGroup(isExpanded: $showAdvancedSettings) {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsCard(title: "Connectivity", subtitle: "Hosted app, signaling, and TURN") {
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
                                        .onChange(of: turnURLString) { newValue in
                                            appState.turnURL = newValue
                                        }

                                    settingsField("TURN username", text: $turnUsername)
                                        .onAppear { turnUsername = appState.turnUsername }
                                        .onChange(of: turnUsername) { newValue in
                                            appState.turnUsername = newValue
                                        }

                                    secureSettingsField("TURN password", text: $turnPassword)
                                        .onAppear { turnPassword = appState.turnPassword }
                                        .onChange(of: turnPassword) { newValue in
                                            appState.turnPassword = newValue
                                        }
                                }

                                Text("TURN is optional. For same-LAN testing it can stay empty. If TURN is configured, username and password should both be set.")
                                    .font(.caption)
                                    .foregroundStyle(GlasstunnelDesign.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        SettingsCard(title: "Diagnostics", subtitle: "Build and host metadata") {
                            VStack(spacing: 12) {
                                diagnosticRow("Host device ID", value: appState.hostDeviceID() ?? "-")
                                diagnosticRow("Protocol version", value: GlasstunnelProtocol.version)
                                diagnosticRow("Session state", value: appState.sessionManagerState)
                                diagnosticRow("Access devices", value: "\(appState.trustedDeviceCount)")
                            }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("Advanced")
                        .font(.headline)
                }
                .padding(20)
                .glasstunnelPanelStyle()

                SettingsCard(title: "Redaction", subtitle: "Built-in and custom secret filters") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Active default patterns")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                            ForEach(SecretRedactor.defaultPatterns, id: \.name) { pattern in
                                Text(pattern.name)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .glasstunnelPanelStyle(radius: GlasstunnelDesign.microRadius)
                            }
                        }

                        Divider()

                        Text("Custom patterns (one regex per line)")
                            .font(.caption)
                            .foregroundStyle(GlasstunnelDesign.muted)
                        TextEditor(text: $customRedactionPatterns)
                            .frame(height: 140)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                                    .fill(GlasstunnelDesign.background)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
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
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
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
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                        .fill(GlasstunnelDesign.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
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
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
                        .fill(GlasstunnelDesign.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GlasstunnelDesign.panelRadius, style: .continuous)
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
}

private struct SettingsCard<Content: View>: View {
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
