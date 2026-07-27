#if os(macOS)
import SwiftUI
import GTSecurity

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.introOnboardingComplete {
                PermissionAccessView()
            } else {
                IntroCarouselView()
            }
        }
        .background(GlasstunnelDesign.background)
    }
}

private struct IntroCarouselView: View {
    @EnvironmentObject var appState: AppState
    @State private var pageIndex = 0
    @State private var animateTunnel = false

    private let pages = OnboardingContentPolicy.introPages

    private var page: OnboardingContentPolicy.IntroPage { pages[pageIndex] }
    private var isLastPage: Bool { pageIndex == pages.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader()

            HStack(spacing: 38) {
                OnboardingHeroIllustration(
                    symbolName: page.primarySymbol,
                    animateTunnel: animateTunnel
                )
                .frame(minWidth: 420, maxWidth: 480, minHeight: 360, maxHeight: 400)

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(page.title)
                            .font(.system(size: 42, weight: .semibold))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = page.subtitle {
                            Text(subtitle)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(GlasstunnelDesign.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 16)

                    HStack(spacing: 10) {
                        ForEach(pages.indices, id: \.self) { index in
                            Capsule(style: .continuous)
                                .fill(index == pageIndex ? GlasstunnelDesign.accent : GlasstunnelDesign.outline.opacity(0.42))
                                .frame(width: index == pageIndex ? 28 : 8, height: 8)
                                .animation(.easeInOut(duration: 0.18), value: pageIndex)
                        }
                    }

                    HStack(spacing: 12) {
                        if pageIndex > 0 {
                            Button("Back") {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    pageIndex -= 1
                                }
                            }
                            .buttonStyle(.bordered)
                            .pointingHandCursor()
                        }

                        Button(isLastPage ? "Set Up Access" : "Next") {
                            if isLastPage {
                                appState.completeIntroOnboarding()
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    pageIndex += 1
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .pointingHandCursor()
                    }
                }
                .frame(maxWidth: 430, maxHeight: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.bottom, 44)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true)) {
                animateTunnel = true
            }
        }
    }
}

private struct PermissionAccessView: View {
    @EnvironmentObject var appState: AppState
    @State private var didScheduleAutoAdvance = false

    private var allPermissionsGranted: Bool {
        appState.requiredPermissionsGranted
    }

    private var summaryState: PermissionSummaryState {
        if !appState.permissionsChecked { return .checking }
        if allPermissionsGranted { return .ready }
        if !appState.requestedPermissions.isEmpty { return .waiting }
        return .needsAccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            BrandHeader()

            VStack(alignment: .leading, spacing: 8) {
                Text(OnboardingContentPolicy.permissionTitle)
                    .font(.system(size: 40, weight: .semibold))
                Text(OnboardingContentPolicy.permissionSubtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(GlasstunnelDesign.muted)
            }

            PermissionSummaryCard(state: summaryState)

            VStack(alignment: .leading, spacing: 0) {
                PermissionRow(
                    permission: .screenRecording,
                    title: "Screen Recording",
                    detail: "Show the Mac screen and agent windows on your phone",
                    systemImage: "rectangle.on.rectangle",
                    granted: appState.screenRecordingGranted
                )

                Divider()
                    .overlay(GlasstunnelDesign.outline.opacity(0.22))
                    .padding(.leading, 60)

                PermissionRow(
                    permission: .accessibility,
                    title: "Accessibility",
                    detail: "Send prompts and clicks back to coding apps",
                    systemImage: "cursorarrow.motionlines",
                    granted: appState.accessibilityGranted
                )
            }
            .padding(.horizontal, 20)
            .glasstunnelPanelStyle(radius: 16)

            Spacer()

            HStack {
                Button {
                    appState.refreshPermissions()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()

                Spacer()

                Button("Continue to Sign In") {
                    appState.continueFromPermissionOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!allPermissionsGranted)
                .pointingHandCursor(allPermissionsGranted)
            }
        }
        .padding(40)
        .onAppear {
            appState.refreshPermissions()
            scheduleAutoAdvanceIfReady()
        }
        .onChange(of: appState.requiredPermissionsGranted) { _ in
            scheduleAutoAdvanceIfReady()
        }
    }

    private func scheduleAutoAdvanceIfReady() {
        guard allPermissionsGranted, !didScheduleAutoAdvance else { return }
        didScheduleAutoAdvance = true
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run {
                appState.continueFromPermissionOnboarding()
            }
        }
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            BrandMarkView(size: 42)
            Text("Glasstunnel")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 40)
        .padding(.top, 34)
        .padding(.bottom, 20)
    }
}

private struct OnboardingHeroIllustration: View {
    let symbolName: String
    let animateTunnel: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            GlasstunnelDesign.surface,
                            GlasstunnelDesign.surfaceAlt.opacity(0.86)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(GlasstunnelDesign.outline.opacity(0.28), lineWidth: 1)
                )

            SecureTunnelLine(animate: animateTunnel)
                .stroke(
                    GlasstunnelDesign.accent.opacity(animateTunnel ? 0.88 : 0.45),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [10, 12])
                )
                .frame(width: 268, height: 110)
                .offset(x: 10, y: -8)
                .animation(.easeInOut(duration: 1.45).repeatForever(autoreverses: true), value: animateTunnel)

            MacMockup()
                .frame(width: 210, height: 150)
                .offset(x: -92, y: -8)

            PhoneMockup(symbolName: symbolName)
                .frame(width: 98, height: 174)
                .offset(x: 128, y: 14)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 22, x: 0, y: 18)
    }
}

private struct MacMockup: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 22 / 255, green: 24 / 255, blue: 27 / 255))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red.opacity(0.85)).frame(width: 7, height: 7)
                        Circle().fill(Color.yellow.opacity(0.85)).frame(width: 7, height: 7)
                        Circle().fill(Color.green.opacity(0.85)).frame(width: 7, height: 7)
                    }
                    .padding(10)
                }
                .overlay {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: "terminal")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(GlasstunnelDesign.accent)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.24))
                                .frame(width: 78, height: 8)
                        }
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(GlasstunnelDesign.accent.opacity(0.62))
                            .frame(width: 92, height: 10)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.30))
                            .frame(width: 132, height: 9)
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 78, height: 9)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(GlasstunnelDesign.success.opacity(0.55))
                                .frame(width: 34, height: 9)
                        }
                    }
                    .padding(.top, 22)
                }
                .frame(height: 128)

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 170, height: 8)
                .padding(.top, 7)
        }
    }
}

private struct PhoneMockup: View {
    let symbolName: String

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(red: 18 / 255, green: 20 / 255, blue: 23 / 255))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 12) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 32, height: 4)
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(GlasstunnelDesign.accent.opacity(0.18))
                            .frame(width: 54, height: 54)
                        Image(systemName: symbolName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(GlasstunnelDesign.accent)
                    }
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 62, height: 18)
                    Spacer()
                }
                .padding(.vertical, 14)
            }
    }
}

private struct SecureTunnelLine: Shape {
    let animate: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 16, y: rect.midY + 22))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 16, y: rect.midY - 14),
            control1: CGPoint(x: rect.midX - 66, y: rect.minY + (animate ? 6 : 22)),
            control2: CGPoint(x: rect.midX + 52, y: rect.maxY - (animate ? 20 : 4))
        )
        return path
    }
}

private struct PermissionSummaryCard: View {
    let state: PermissionSummaryState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(state.color.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: state.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline)
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundStyle(GlasstunnelDesign.muted)
            }

            Spacer()
        }
        .padding(18)
        .glasstunnelPanelStyle(radius: 16)
    }
}

private struct PermissionRow: View {
    @EnvironmentObject var appState: AppState

    let permission: Permissions.Permission
    let title: String
    let detail: String
    let systemImage: String
    let granted: Bool

    private var state: PermissionVisualState {
        PermissionVisualState(
            granted: granted,
            checking: !appState.permissionsChecked,
            requested: appState.permissionWasRequested(permission)
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                if state == .checking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: state.leadingSystemImage(fallback: systemImage))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(state.color)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(state.detail(defaultDetail: detail))
                    .font(.subheadline)
                    .foregroundStyle(GlasstunnelDesign.muted)
            }

            Spacer()

            HStack(spacing: 10) {
                PermissionStatusPill(state: state)
                if let actionTitle = state.actionTitle {
                    Button(actionTitle) {
                        switch state {
                        case .needsAccess:
                            appState.requestPermission(permission)
                        case .waiting:
                            appState.refreshPermissions()
                        case .checking, .allowed:
                            break
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                }
            }
        }
        .frame(minHeight: 82)
    }
}

private enum PermissionSummaryState {
    case checking
    case ready
    case needsAccess
    case waiting

    var title: String {
        switch self {
        case .checking: return "Checking access"
        case .ready: return "Access granted"
        case .needsAccess: return "Finish access"
        case .waiting: return "Waiting for macOS"
        }
    }

    var detail: String {
        switch self {
        case .checking: return "Reading the current Mac settings."
        case .ready: return "Opening sign in."
        case .needsAccess: return "Grant both permissions below."
        case .waiting: return "Turn the permission on in System Settings, then return here."
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "hourglass"
        case .ready: return "checkmark.seal.fill"
        case .needsAccess: return "shield.lefthalf.filled.badge.checkmark"
        case .waiting: return "gearshape.2"
        }
    }

    var color: Color {
        switch self {
        case .checking: return GlasstunnelDesign.muted
        case .ready: return GlasstunnelDesign.success
        case .needsAccess: return GlasstunnelDesign.warning
        case .waiting: return GlasstunnelDesign.accent
        }
    }
}

private enum PermissionVisualState: Equatable {
    case checking
    case allowed
    case needsAccess
    case waiting

    init(granted: Bool, checking: Bool, requested: Bool) {
        if checking {
            self = .checking
        } else if granted {
            self = .allowed
        } else if requested {
            self = .waiting
        } else {
            self = .needsAccess
        }
    }

    var label: String {
        switch self {
        case .checking: return "Checking"
        case .allowed: return "Allowed"
        case .needsAccess: return "Needs access"
        case .waiting: return "Waiting"
        }
    }

    var pillSystemImage: String {
        switch self {
        case .checking: return "hourglass"
        case .allowed: return "checkmark"
        case .needsAccess: return "exclamationmark"
        case .waiting: return "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .checking: return GlasstunnelDesign.muted
        case .allowed: return GlasstunnelDesign.success
        case .needsAccess: return GlasstunnelDesign.warning
        case .waiting: return GlasstunnelDesign.accent
        }
    }

    var actionTitle: String? {
        switch self {
        case .needsAccess:
            return "Grant"
        case .waiting:
            return "Recheck"
        case .checking, .allowed:
            return nil
        }
    }

    func detail(defaultDetail: String) -> String {
        switch self {
        case .checking, .needsAccess:
            return defaultDetail
        case .allowed:
            return "Ready"
        case .waiting:
            return "Turn it on in System Settings"
        }
    }

    func leadingSystemImage(fallback: String) -> String {
        switch self {
        case .checking: return fallback
        case .allowed: return "checkmark"
        case .needsAccess: return fallback
        case .waiting: return "gearshape"
        }
    }
}

private struct PermissionStatusPill: View {
    let state: PermissionVisualState

    var body: some View {
        Label(state.label, systemImage: state.pillSystemImage)
            .font(.system(size: 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(state.color.opacity(0.14))
            )
            .foregroundStyle(state.color)
    }
}
#endif
