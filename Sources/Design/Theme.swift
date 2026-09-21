import SwiftUI
import AppKit

// MARK: - Palette

/// Colour vocabulary built on **semantic system colours** rather than fixed
/// RGB values, so the app adapts correctly to light/dark mode, increased
/// contrast and the user's chosen accent colour — the way Apple's own apps do.
enum Palette {

    // MARK: Surfaces

    /// Window chrome behind the sidebar.
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    /// The main content area, slightly raised from the window.
    static let contentBackground = Color(nsColor: .controlBackgroundColor)
    /// Grouped rows and cards.
    static let card = Color(nsColor: .controlBackgroundColor)
    /// Fill for text fields and wells.
    static let field = Color(nsColor: .textBackgroundColor)
    /// Sidebar selection and hover states.
    static let hover = Color.primary.opacity(0.055)

    // MARK: Lines

    /// Hairline separators, matching AppKit's own separator weight.
    static let separator = Color(nsColor: .separatorColor)
    static let border = Color.primary.opacity(0.09)
    static let borderStrong = Color.primary.opacity(0.16)

    // MARK: Text

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textQuaternary = Color(nsColor: .quaternaryLabelColor)

    // MARK: Semantic status

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    // MARK: Accent

    /// The user's system accent, used for the primary action everywhere.
    static let accent = Color.accentColor
}

// MARK: - Category colouring

/// Categories keep a small, muted tint purely as a wayfinding cue. They are
/// deliberately low-saturation so the interface stays calm, and they are drawn
/// from the system palette so they harmonise with the OS.
enum CategoryTint {
    static func color(_ category: ToolCategory) -> Color {
        switch category {
        case .video: return Color(nsColor: .systemBlue)
        case .image: return Color(nsColor: .systemPink)
        case .document: return Color(nsColor: .systemTeal)
        case .archive: return Color(nsColor: .systemOrange)
        case .utility: return Color(nsColor: .systemPurple)
        }
    }
}

// MARK: - Metrics

/// A single 4-point spacing scale, so every gap in the app is a multiple of it.
enum Metrics {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20

    /// Primary action button width.
    ///
    /// The label decides the width between these bounds: a short label gets the
    /// minimum, a long one grows, and anything past the maximum wraps onto a
    /// second line instead of widening further. Measured: at 190pt every action
    /// title in all 12 languages fits within two lines (the text area is
    /// 138pt), so the button never needs a third line or a wider cap.
    static let buttonMinWidth: CGFloat = 148
    static let buttonMaxWidth: CGFloat = 190

    /// Settings pane size. Wide enough that the longest translations — Spanish
    /// and Portuguese run about 2.5× the English — still fit on one line.
    static let settingsPaneWidth: CGFloat = 560
    static let settingsPaneHeight: CGFloat = 620
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 8
    static let radiusLarge: CGFloat = 12

    /// Sidebar width.
    ///
    /// Measured against the longest tool name in each of the 12 languages: at
    /// the previous 224pt even the English "Rounded corners, border and shadow"
    /// was clipped, and Russian needed three lines. At 250pt every language
    /// fits within two lines, which the rows are sized to show.
    static let sidebarWidth: CGFloat = 250
    /// Wide enough for the three inspector tabs to sit side by side in every
    /// language.
    ///
    /// Measured, not guessed: the segmented control itself needs 320pt in
    /// Russian (the widest), plus 12pt padding each side, 8pt spacing and a
    /// 20pt close button — 372pt. At the previous 300pt the Russian and German
    /// tabs fell back to a menu, which works but hides two of the three.
    static let inspectorWidth: CGFloat = 380

    /// Standard control height, matching AppKit's regular control size.
    static let controlHeight: CGFloat = 22
    /// Comfortable row height for touch-friendly list items.
    static let rowHeight: CGFloat = 28
    /// Prominent button height.
    static let buttonHeight: CGFloat = 32
}

// MARK: - Typography

/// Named text styles mapped onto the system font scale, so the app matches
/// macOS typography instead of inventing its own sizes.
enum Type {
    static let title = Font.system(size: 15, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let footnote = Font.system(size: 11)
    static let caption = Font.system(size: 10.5)
    static let caption2 = Font.system(size: 10)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Category

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case video, image, document, archive, utility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return L("ui.video")
        case .image: return L("ui.image")
        case .document: return L("enum.mediakind.video")
        case .archive: return L("enum.category.video")
        case .utility: return L("enum.category.video.2")
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .utility: return "wrench.and.screwdriver"
        }
    }

    var accent: Color { CategoryTint.color(self) }
}

// MARK: - Motion

enum Motion {
    /// Matches AppKit's default animation feel.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let smooth = Animation.easeInOut(duration: 0.2)
    static let quick = Animation.easeOut(duration: 0.12)
}

// MARK: - View helpers

extension View {
    /// A grouped content card, styled like a macOS settings pane.
    func card(padding: CGFloat = Metrics.s4) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                    .fill(Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
    }

    /// Standard hairline separator.
    func hairline() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    /// "2.1 MP" style pixel counts.
    static func pixels(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1f MP", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0f K", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Reduce a ratio to its simplest useful form, e.g. 16:9.
    static func aspect(width: CGFloat, height: CGFloat) -> String {
        guard width > 0, height > 0 else { return "—" }
        let divisor = greatestCommonDivisor(Int(width.rounded()), Int(height.rounded()))
        guard divisor > 0 else { return "—" }
        let w = Int(width.rounded()) / divisor
        let h = Int(height.rounded()) / divisor
        // Very large reduced terms are unhelpful; fall back to a decimal.
        if w > 40 || h > 40 {
            return String(format: "%.2f:1", width / height)
        }
        return "\(w):\(h)"
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}
