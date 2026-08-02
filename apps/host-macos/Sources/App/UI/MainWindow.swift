#if os(macOS)
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var profilePopoverPresented = false
    @State private var sidebarCollapsed = false

    var body: some View {
        Group {
            if appState.shouldShowPermissionOnboarding {
                OnboardingView()
            } else {
                accountRouteView
            }
        }
        .onAppear { appState.refreshPermissions() }
        .preferredColorScheme(.dark)
        .foregroundStyle(GlasstunnelDesign.text)
        .tint(GlasstunnelDesign.accent)
    }

    @ViewBuilder
    private var accountRouteView: some View {
        switch appState.accountRoute {
        case .checkingAccount:
            AccountCheckingView()
        case .signIn:
            AccountLinkGateView()
        case .workspace:
            VStack(spacing: 0) {
                header
                Divider()
                HSplitView {
                    sidebar
                        .frame(
                            minWidth: sidebarCollapsed ? 72 : 196,
                            idealWidth: sidebarCollapsed ? 76 : 212,
                            maxWidth: sidebarCollapsed ? 84 : 224
                        )
                        .background(GlasstunnelDesign.surface)
                        .animation(.easeInOut(duration: 0.18), value: sidebarCollapsed)

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GlasstunnelDesign.background)
                }
            }
            .background(GlasstunnelDesign.background)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                BrandMarkView(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glasstunnel")
                        .font(.title3.weight(.semibold))
                    Text(appState.hostDisplayName)
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.muted)
                }
            }

            Spacer()

            HeaderPill(
                title: appState.hostStatusLabel,
                subtitle: appState.activeConnectionSummary,
                tone: headerTone(for: appState.sessionManagerState)
            )

            Button {
                profilePopoverPresented.toggle()
            } label: {
                AvatarBadge(
                    label: avatarLabel,
                    accent: appState.isLinkedToAccount
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popover(isPresented: $profilePopoverPresented, arrowEdge: .top) {
                ProfilePopoverView(isPresented: $profilePopoverPresented)
                    .environmentObject(appState)
                    .frame(width: 280)
                    .padding(18)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(GlasstunnelDesign.background)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    VStack(spacing: 4) {
                        navigationButton(for: .workspace, badge: nil)
                        navigationButton(for: .access, badge: nil)
                        navigationButton(for: .settings, badge: nil)
                    }
                    .padding(.horizontal, 10)

                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .padding(.bottom, 12)
            }

            Divider()
                .overlay(GlasstunnelDesign.border)

            sidebarToggleFooter
                .padding(10)
        }
    }

    private var sidebarToggleFooter: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(sidebarCollapsed ? 180 : 0))
                    .animation(.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.08), value: sidebarCollapsed)
                    .frame(width: 32, height: 28)
                if sidebarCollapsed {
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(GlasstunnelDesign.muted)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .fill(GlasstunnelDesign.surfaceAlt.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .stroke(GlasstunnelDesign.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(sidebarCollapsed ? "Expand navigation" : "Collapse navigation")
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selectedTab {
        case .workspace:
            WorkspaceView()
        case .access:
            AccessView()
        case .settings:
            SettingsView()
        }
    }

    private func navigationButton(for tab: AppNavigationTab, badge: Int?) -> some View {
        Button {
            appState.selectTab(tab)
        } label: {
            Group {
                if sidebarCollapsed {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 18, height: 18)
                        if let badge {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                                        .fill(GlasstunnelDesign.accent.opacity(0.15))
                                )
                                .foregroundStyle(GlasstunnelDesign.accent)
                                .offset(x: 10, y: -10)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        if let badge {
                            Text("\(badge)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                                        .fill(GlasstunnelDesign.accent.opacity(0.15))
                                )
                                .foregroundStyle(GlasstunnelDesign.accent)
                        }
                    }
                }
            }
            .padding(.horizontal, sidebarCollapsed ? 10 : 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .fill(appState.selectedTab == tab ? GlasstunnelDesign.accent.opacity(0.14) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .stroke(appState.selectedTab == tab ? GlasstunnelDesign.accent.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(tab.title)
    }

    private var avatarLabel: String {
        if let linkedAccount = appState.linkedAccount {
            let source = linkedAccount.displayName.isEmpty ? linkedAccount.email : linkedAccount.displayName
            let parts = source.split(separator: " ")
            let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
            if !initials.isEmpty { return initials.uppercased() }
            if let first = source.first { return String(first).uppercased() }
        }
        return "GT"
    }

    private func headerTone(for state: String) -> HeaderPill.Tone {
        switch state {
        case "connected": return .ok
        case "connecting": return .warn
        case "error": return .warn
        default: return .neutral
        }
    }

}

private struct AccountCheckingView: View {
    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()

            Spacer()

            VStack(spacing: 18) {
                BrandMarkView(size: 64)
                ProgressView()
                    .controlSize(.small)
                VStack(spacing: 8) {
                    Text("Checking account")
                        .font(.system(size: 38, weight: .semibold))
                    Text("Confirming this Mac's account link.")
                        .font(.system(size: 16))
                        .foregroundStyle(GlasstunnelDesign.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .background(GlasstunnelDesign.background)
    }
}

private struct AccountLinkGateView: View {
    @EnvironmentObject var appState: AppState
    @State private var openingMethod: AppState.HostedAuthMethod? = nil
    @State private var accountError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()

            Spacer()

            VStack(spacing: 18) {
                BrandMarkView(size: 64)

                VStack(spacing: 8) {
                    Text("Sign in")
                        .font(.system(size: 38, weight: .semibold))
                    Text(signInSubtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(GlasstunnelDesign.muted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    HostedAuthButton(
                        title: "Continue with Google",
                        busyTitle: "Opening Google...",
                        method: .google,
                        openingMethod: openingMethod,
                        style: .google,
                        action: beginHostedSignIn
                    )

                    HostedAuthButton(
                        title: "Continue with GitHub",
                        busyTitle: "Opening GitHub...",
                        method: .github,
                        openingMethod: openingMethod,
                        style: .github,
                        action: beginHostedSignIn
                    )

                    HostedAuthButton(
                        title: "Continue with email",
                        busyTitle: "Opening email sign in...",
                        method: .email,
                        openingMethod: openingMethod,
                        style: .plain,
                        action: beginHostedSignIn
                    )
                }
                .frame(width: 320)

                if let accountError {
                    Text(accountError)
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .background(GlasstunnelDesign.background)
    }

    private var signInSubtitle: String {
        openingMethod == nil ? "Link this Mac to your account." : "Complete sign in in your browser."
    }

    @MainActor
    private func beginHostedSignIn(_ method: AppState.HostedAuthMethod) async {
        guard openingMethod == nil else { return }
        accountError = nil
        openingMethod = method
        defer { openingMethod = nil }
        do {
            try await appState.beginHostedAccountSignIn(method: method)
        } catch {
            accountError = error.localizedDescription
        }
    }
}

private struct HostedAuthButton: View {
    enum Style {
        case google
        case github
        case plain

        var foreground: Color {
            switch self {
            case .google: return Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255)
            case .github, .plain: return GlasstunnelDesign.text
            }
        }

        var background: Color {
            switch self {
            case .google: return .white
            case .github: return Color(red: 23 / 255, green: 21 / 255, blue: 21 / 255)
            case .plain: return GlasstunnelDesign.surfaceAlt.opacity(0.55)
            }
        }

        var border: Color {
            switch self {
            case .google: return Color.white.opacity(0.92)
            case .github: return Color.white.opacity(0.16)
            case .plain: return GlasstunnelDesign.border
            }
        }
    }

    let title: String
    let busyTitle: String
    let method: AppState.HostedAuthMethod
    let openingMethod: AppState.HostedAuthMethod?
    let style: Style
    let action: @MainActor (AppState.HostedAuthMethod) async -> Void

    private var isBusy: Bool { openingMethod == method }
    private var isDisabled: Bool { openingMethod != nil }

    var body: some View {
        Button {
            Task { await action(method) }
        } label: {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(style.foreground)
                } else {
                    authIcon
                }

                Text(isBusy ? busyTitle : title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(style.foreground)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(style.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isBusy ? 0.45 : 1)
        .pointingHandCursor(!isDisabled)
    }

    @ViewBuilder
    private var authIcon: some View {
        switch method {
        case .google:
            SVGAuthMark(svg: AuthProviderSVG.google)
                .frame(width: 18, height: 18)
        case .github:
            SVGAuthMark(svg: AuthProviderSVG.github)
                .frame(width: 18, height: 18)
        case .email:
            Image(systemName: "envelope.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GlasstunnelDesign.muted)
        }
    }
}

private struct SVGAuthMark: View {
    let svg: String

    var body: some View {
        Group {
            if let image = Self.image(from: svg) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .accessibilityHidden(true)
    }

    private static func image(from svg: String) -> NSImage? {
        NSImage(data: Data(svg.utf8))
    }
}

private enum AuthProviderSVG {
    static let google = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18">
      <path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.9c1.7-1.56 2.7-3.86 2.7-6.62Z"/>
      <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.9-2.26c-.8.54-1.84.86-3.06.86-2.35 0-4.33-1.58-5.04-3.7H.96v2.34A9 9 0 0 0 9 18Z"/>
      <path fill="#FBBC05" d="M3.96 10.72A5.41 5.41 0 0 1 3.68 9c0-.6.1-1.18.28-1.72V4.94H.96A9 9 0 0 0 0 9c0 1.45.35 2.82.96 4.06l3-2.34Z"/>
      <path fill="#EA4335" d="M9 3.58c1.32 0 2.5.46 3.44 1.36l2.58-2.58C13.46.92 11.43 0 9 0A9 9 0 0 0 .96 4.94l3 2.34C4.67 5.16 6.65 3.58 9 3.58Z"/>
    </svg>
    """

    static let github = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="#FDFCFC">
      <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.6 7.6 0 0 1 8 4.57c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8 8 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/>
    </svg>
    """
}

private struct HeaderPill: View {
    enum Tone {
        case neutral
        case accent
        case ok
        case warn

        var fill: Color {
            switch self {
            case .neutral: return GlasstunnelDesign.surfaceAlt
            case .accent: return GlasstunnelDesign.accent.opacity(0.16)
            case .ok: return GlasstunnelDesign.success.opacity(0.16)
            case .warn: return GlasstunnelDesign.warning.opacity(0.18)
            }
        }

        var stroke: Color {
            switch self {
            case .neutral: return GlasstunnelDesign.outline
            case .accent: return GlasstunnelDesign.accent.opacity(0.45)
            case .ok: return GlasstunnelDesign.success.opacity(0.45)
            case .warn: return GlasstunnelDesign.warning.opacity(0.45)
            }
        }

        var titleColor: Color {
            switch self {
            case .neutral: return GlasstunnelDesign.text
            case .accent: return GlasstunnelDesign.accent
            case .ok: return GlasstunnelDesign.success
            case .warn: return GlasstunnelDesign.warning
            }
        }
    }

    let title: String
    let subtitle: String
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone.titleColor)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(GlasstunnelDesign.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .fill(tone.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .stroke(tone.stroke, lineWidth: 1)
        )
    }
}

private struct AvatarBadge: View {
    let label: String
    let accent: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(accent ? GlasstunnelDesign.accent.opacity(0.18) : GlasstunnelDesign.surfaceAlt)
                .frame(width: 36, height: 36)
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent ? GlasstunnelDesign.accent : GlasstunnelDesign.text)
        }
        .overlay(
            Circle()
                .stroke(accent ? GlasstunnelDesign.accent.opacity(0.4) : GlasstunnelDesign.outline, lineWidth: 1)
        )
    }
}

private struct ProfilePopoverView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var showingSignOutConfirmation = false
    @State private var accountActionInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarBadge(
                    label: profileInitials,
                    accent: appState.isLinkedToAccount
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.linkedAccount?.displayName ?? "No account linked")
                        .font(.headline)
                    Text(appState.linkedAccount?.email ?? "Sign in to link this Mac")
                        .font(.caption)
                        .foregroundStyle(GlasstunnelDesign.muted)
                }
            }

            Divider()

            Button {
                appState.selectTab(.access)
                isPresented = false
            } label: {
                Label("Manage Access", systemImage: AppNavigationTab.access.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Button {
                appState.selectTab(.settings)
                isPresented = false
            } label: {
                Label("Settings", systemImage: AppNavigationTab.settings.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Divider()

            if appState.isLinkedToAccount {
                Button(role: .destructive) {
                    showingSignOutConfirmation = true
                } label: {
                    if accountActionInFlight {
                        Label("Signing out…", systemImage: "arrow.left.circle")
                    } else {
                        Label("Sign Out", systemImage: "arrow.left.circle")
                    }
                }
                .buttonStyle(.plain)
                .disabled(accountActionInFlight)
                .pointingHandCursor(!accountActionInFlight)
            } else {
                Button {
                    Task { await beginHostedSignIn() }
                } label: {
                    if accountActionInFlight {
                        Label("Opening sign in…", systemImage: "person.crop.circle.badge.plus")
                    } else {
                        Label("Sign in & Link Mac", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .buttonStyle(.plain)
                .disabled(accountActionInFlight)
                .pointingHandCursor(!accountActionInFlight)
            }

            Text("Glasstunnel \(AppVersionInfo.current().displayValue)")
                .font(.caption2)
                .foregroundStyle(GlasstunnelDesign.muted)
        }
        .foregroundStyle(GlasstunnelDesign.text)
        .confirmationDialog("Sign out of this Mac?", isPresented: $showingSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                Task { await signOutLinkedAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unlinks the Mac from your account and clears all access devices on this Mac.")
        }
    }

    private var profileInitials: String {
        if let linkedAccount = appState.linkedAccount {
            let source = linkedAccount.displayName.isEmpty ? linkedAccount.email : linkedAccount.displayName
            let pieces = source.split(separator: " ")
            let initials = pieces.prefix(2).compactMap { $0.first }.map(String.init).joined()
            if !initials.isEmpty { return initials.uppercased() }
        }
        return "GT"
    }

    private func beginHostedSignIn() async {
        accountActionInFlight = true
        defer { accountActionInFlight = false }
        do {
            try await appState.beginHostedAccountSignIn()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func signOutLinkedAccount() async {
        accountActionInFlight = true
        defer { accountActionInFlight = false }
        do {
            try await appState.signOutLinkedAccount()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }
}
#endif
