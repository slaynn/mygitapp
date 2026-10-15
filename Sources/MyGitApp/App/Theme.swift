import AppKit
import MarkdownUI
import SwiftUI

/// Palette for both appearances: dark matches the reference screenshot, light follows GitHub's light theme.
enum Theme {
    static let background = Color.adaptive(light: 0xFFFFFF, dark: 0x111113)
    static let panel = Color.adaptive(light: 0xF6F8FA, dark: 0x17181B)
    static let raised = Color.adaptive(light: 0xEFF2F5, dark: 0x1D1E22)
    static let border = Color.adaptive(light: Color.black.opacity(0.11), dark: Color.white.opacity(0.08))
    static let hover = Color.adaptive(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.04))
    /// Subtle fill for placeholders, counters and selected tabs.
    static let fill = Color.adaptive(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    /// Text drawn on a filled accent color.
    static let onAccent = Color.adaptive(light: Color.white, dark: Color.black.opacity(0.85))

    static let green = Color.adaptive(light: 0x1A7F37, dark: 0x3FB950)
    static let red = Color.adaptive(light: 0xCF222E, dark: 0xF85149)
    static let yellow = Color.adaptive(light: 0x9A6700, dark: 0xD29922)
    static let orange = Color.adaptive(light: 0xBC4C00, dark: 0xE8A33D)
    static let purple = Color.adaptive(light: 0x8250DF, dark: 0xA371F7)
    static let blue = Color.adaptive(light: 0x0969DA, dark: 0x58A6FF)
    static let gray = Color.adaptive(light: 0x59636E, dark: 0x8B949E)

    /// Height of the bar under the title bar (sidebar profile row, repo bar), so both sides line up.
    static let topBarHeight: CGFloat = 48

    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)

    static func color(for status: CIStatus) -> Color {
        switch status {
        case .success: green
        case .failure: red
        case .pending: yellow
        case .neutral, .none: gray
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Resolves to `light` or `dark` with the view's appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        adaptive(light: Color(hex: light), dark: Color(hex: dark))
    }

    /// `#3178c6` → Color
    init?(hexString: String?) {
        guard let hexString, let value = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// Window appearance, chosen in the View menu.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension Date {
    /// Compact relative time: `now`, `5m`, `8h`, `3d`, `2w`, `4mo`, `1y`.
    var shortAgo: String {
        let seconds = Int(Date.now.timeIntervalSince(self))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        case ..<(86_400 * 7): return "\(seconds / 86_400)d"
        case ..<(86_400 * 30): return "\(seconds / (86_400 * 7))w"
        case ..<(86_400 * 365): return "\(seconds / (86_400 * 30))mo"
        default: return "\(seconds / (86_400 * 365))y"
        }
    }
}

extension MarkdownUI.Theme {
    /// GitHub theme sized for dense comment threads, without its opaque background.
    static let app = MarkdownUI.Theme.gitHub
        .text {
            ForegroundColor(.primary)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Theme.fill)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 8)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 8)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.25)) }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.1)) }
        }
}
