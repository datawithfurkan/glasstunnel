#if os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Copy that tells people the phone side of Glasstunnel is the web app, and how to reach it.
struct PhoneAccessContent {
    static let buttonTitle = "Open on Phone"
    static let buttonHelp = "Show how to open Glasstunnel on your phone"
    static let title = "Use Glasstunnel on your phone"
    static let subtitle = "Your phone opens this Mac through the Glasstunnel web app. There is nothing to install from an app store."

    /// The address as people type it: no scheme and no trailing slash.
    static func displayAddress(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return url.absoluteString
        }
        var address = host
        if let port = components.port {
            address += ":\(port)"
        }
        let path = components.path
        if !path.isEmpty, path != "/" {
            address += path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return address
    }

    static func steps(address: String, accountEmail: String?, macName: String?) -> [String] {
        let signIn: String
        if let accountEmail, !accountEmail.isEmpty {
            signIn = "Sign in as \(accountEmail), the account this Mac uses."
        } else {
            signIn = "Sign in with the same account as this Mac."
        }
        let pick: String
        if let macName, !macName.isEmpty {
            pick = "Choose \(macName), then open an app or its screen."
        } else {
            pick = "Choose this Mac, then open an app or its screen."
        }
        return [
            "Scan the code with your phone's camera, or visit \(address).",
            signIn,
            pick
        ]
    }

    /// Shown under the Mac's sign-in buttons so the next step is clear before it happens.
    static func signInNextStep(address: String) -> String {
        "Next, open \(address) on your phone and sign in with the same account."
    }
}

enum PhoneAccessQRCode {
    /// A QR code for `url`, scaled by whole pixels so the modules stay sharp and scannable.
    static func cgImage(for url: URL, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#endif
