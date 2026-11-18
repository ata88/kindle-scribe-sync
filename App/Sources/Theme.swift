import AppKit
import SwiftUI

/// Design tokens and small shared components, so every screen looks the same.
enum Theme {
    static let accent = Color(red: 0.16, green: 0.50, blue: 0.44)       // teal of the app icon
    static let warm = Color(red: 0.91, green: 0.59, blue: 0.22)         // orange sync badge
    static let paper = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.13, alpha: 1) : NSColor(red: 0.995, green: 0.99, blue: 0.975, alpha: 1)
    })
    static let scanBackground = Color.white
    static let hairline = Color(nsColor: .separatorColor)

    static let readingWidth: CGFloat = 720
    static let corner: CGFloat = 10
    static let bodyFont = Font.system(size: 15)
    static let bodyLineSpacing: CGFloat = 4
}

/// Rounded surface used for cards and panels.
struct Surface<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

/// Small capsule label ("korrigiert", "3 Hinweise" …).
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// A key/value row in cards and the diagnostics window.
struct InfoRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? .callout.monospacedDigit() : .callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Placeholder lines that gently pulse while a page is being read.
struct SkeletonLines: View {
    var lines = 5
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<lines, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(phase ? 0.10 : 0.18))
                    .frame(height: 11)
                    .frame(maxWidth: i == lines - 1 ? 260 : .infinity, alignment: .leading)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

extension View {
    /// Hover highlight used for clickable rows.
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}
