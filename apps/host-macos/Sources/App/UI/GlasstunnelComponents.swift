#if os(macOS)
import SwiftUI

struct GlasstunnelPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(GlasstunnelDesign.muted)
        }
    }
}

struct GlasstunnelGroupedList<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .fill(GlasstunnelDesign.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                .stroke(GlasstunnelDesign.border, lineWidth: 1)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
        )
    }
}

struct GlasstunnelGroupHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GlasstunnelListRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color
    private let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color = GlasstunnelDesign.muted,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: GlasstunnelDesign.microRadius, style: .continuous)
                    .fill(iconColor.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GlasstunnelDesign.text)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GlasstunnelDesign.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GlasstunnelRowDivider: View {
    var leadingInset: CGFloat = 64

    var body: some View {
        Rectangle()
            .fill(GlasstunnelDesign.outline.opacity(0.20))
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

struct GlasstunnelStatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
#endif
