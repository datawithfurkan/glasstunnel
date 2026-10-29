#if os(macOS)
import AppKit
import SwiftUI

/// The header button that explains how to reach this Mac from a phone.
struct OpenOnPhoneButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(PhoneAccessContent.buttonTitle, systemImage: "iphone")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .pointingHandCursor()
        .help(PhoneAccessContent.buttonHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PhoneAccessPopover()
                .environmentObject(appState)
        }
    }
}

/// The phone instructions sized for a popover.
struct PhoneAccessPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        PhoneAccessPanel(
            webAppURL: appState.webAppURL,
            accountEmail: appState.linkedAccount?.email,
            macName: appState.linkedAccount?.hostLabel
        )
            .frame(width: 420)
            .padding(18)
            .foregroundStyle(GlasstunnelDesign.text)
            .preferredColorScheme(.dark)
    }
}

/// A scannable link to the web app, the steps after it, and ways to open or copy it.
struct PhoneAccessPanel: View {
    let webAppURL: URL
    let accountEmail: String?
    let macName: String?
    @State private var qrImage: CGImage? = nil
    @State private var copied = false

    private var address: String {
        PhoneAccessContent.displayAddress(for: webAppURL)
    }

    private var steps: [String] {
        PhoneAccessContent.steps(address: address, accountEmail: accountEmail, macName: macName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PhoneAccessContent.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(PhoneAccessContent.subtitle)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                qrCode

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(GlasstunnelDesign.accent)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(GlasstunnelDesign.accent.opacity(0.16)))
                            Text(step)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 1)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(webAppURL)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(webAppURL.absoluteString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()

                Spacer(minLength: 0)
            }
        }
        .onAppear { qrImage = PhoneAccessQRCode.cgImage(for: webAppURL) }
        .onChange(of: webAppURL) { url in
            qrImage = PhoneAccessQRCode.cgImage(for: url)
        }
    }

    private var qrCode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .fill(Color.white)
            if let qrImage {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .padding(10)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.black.opacity(0.35))
            }
        }
        .frame(width: 148, height: 148)
        .accessibilityElement()
        .accessibilityLabel("QR code for \(address)")
    }
}
#endif
