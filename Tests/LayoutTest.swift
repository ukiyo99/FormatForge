import AppKit

// Check every translated string against the space its container really offers.
//
// This exists because a fixed-width action button clipped 186 translated
// titles — including the English "Take Screenshots" — and the 224pt sidebar
// cut off tool names in ten languages. Text that cannot wrap has to be
// measured, not assumed.
//
// Sidebar rows wrap to two lines, so the budget there is two lines' worth.
// The action button and picker options size themselves to their content.
@main struct A {
    static var problems = 0

    static func width(_ s: String, _ size: CGFloat) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    /// Lines a string occupies at the given width.
    static func lines(_ s: String, width: CGFloat, size: CGFloat,
                      weight: NSFont.Weight = .regular) -> Int {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let one = ("X" as NSString).size(withAttributes: [.font: font]).height
        let rect = (s as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return max(1, Int((rect.height / one).rounded()))
    }

    static func checkWrapped(_ label: String, _ text: String, available: CGFloat,
                             size: CGFloat, maxLines: Int, lang: String,
                             weight: NSFont.Weight = .regular) {
        let n = lines(text, width: available, size: size, weight: weight)
        if n > maxLines {
            print(String(format: "  ✗ %-8s %-20s needs %d lines (limit %d)  %@",
                         (lang as NSString).utf8String!, (label as NSString).utf8String!,
                         n, maxLines, text))
            problems += 1
        }
    }

    static func checkFits(_ label: String, _ text: String, available: CGFloat,
                          size: CGFloat, lang: String) {
        let w = width(text, size)
        if w > available {
            print(String(format: "  ✗ %-8s %-20s %5.0fpt > %3.0fpt  %@",
                         (lang as NSString).utf8String!, (label as NSString).utf8String!,
                         w, available, text))
            problems += 1
        }
    }

    static func main() {
        // Sidebar rows wrap to 2 lines.
        let sidebarText = Metrics.sidebarWidth - (8 + 8 + 18 + 8 + 8 + 24)
        // Parameter labels wrap to 2 lines in a form row.
        let paramWidth: CGFloat = 430
        // Picker menus truncate with a tooltip, so only flag absurd lengths.
        let pickerWidth: CGFloat = 420

        print("Sidebar text \(Int(sidebarText))pt (2 lines)  Button \(Int(Metrics.buttonMaxWidth))pt (2 lines)  Params \(Int(paramWidth))pt  Options \(Int(pickerWidth))pt\n")

        for language in Language.allCases {
            LanguageStore.shared.setLanguage(language)
            ToolRegistry.invalidate()
            let lang = language.rawValue

            for tool in ToolRegistry.all {
                checkWrapped("sidebar name", tool.name, available: sidebarText,
                             size: 13, maxLines: 2, lang: lang)
                // The action button grows to fit its label and wraps to two
                // lines past the maximum, so the real constraint is that the
                // title fits within two lines at the capped text width.
                //
                // Only conversion tools get a button; inspection tools have
                // none, so their names are not held to this.
                if tool.needsRunButton {
                    let buttonText = Metrics.buttonMaxWidth - (16 * 2 + 14 + 6)
                    checkWrapped("action button", tool.actionTitle ?? tool.name,
                                 available: buttonText, size: 13, maxLines: 2,
                                 lang: lang, weight: .semibold)
                }
                for parameter in tool.parameters {
                    checkWrapped("param label", parameter.label, available: paramWidth,
                                 size: 13, maxLines: 2, lang: lang)
                    if case .picker(let options) = parameter.kind {
                        for option in options {
                            checkFits("picker option", option.label,
                                      available: pickerWidth, size: 13, lang: lang)
                        }
                    }
                }
            }
        }
        print()
        print(problems == 0 ? "RESULT PASS — nothing clipped" : "RESULT FAIL — \(problems) too wide")
        LanguageStore.shared.setLanguage(.english)
        exit(problems == 0 ? 0 : 1)
    }
}
