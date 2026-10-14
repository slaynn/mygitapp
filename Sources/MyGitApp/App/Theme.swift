import MarkdownUI
import SwiftUI

/// Dark palette matching the reference screenshot.
enum Theme {
    static let background = Color(hex: 0x111113)
    static let panel = Color(hex: 0x17181B)
    static let raised = Color(hex: 0x1D1E22)
    static let border = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.04)

    static let green = Color(hex: 0x3FB950)
    static let red = Color(hex: 0xF85149)
    static let yellow = Color(hex: 0xD29922)
    static let orange = Color(hex: 0xE8A33D)
    static let purple = Color(hex: 0xA371F7)
    static let blue = Color(hex: 0x58A6FF)
    static let gray = Color(hex: 0x8B949E)

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

    /// `#3178c6` → Color
    init?(hexString: String?) {
        guard let hexString, let value = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(hex: value)
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
            BackgroundColor(Color.white.opacity(0.08))
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
