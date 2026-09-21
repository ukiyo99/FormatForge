import Foundation
import AppKit
import PDFKit

/// Bidirectional Markdown ⇄ NSAttributedString conversion, written from
/// scratch so the app has no external pandoc dependency.
enum MarkdownConverter {

    // MARK: - Markdown → Attributed

    static func attributed(from markdown: String, baseFontSize: CGFloat = 13) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        var inCodeFence = false
        var codeBuffer: [String] = []

        let bodyFont = NSFont.systemFont(ofSize: baseFontSize)
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular)

        func appendParagraph(_ text: NSAttributedString, spacingAfter: CGFloat = 6) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacingAfter
            paragraph.lineSpacing = 2
            let mutable = NSMutableAttributedString(attributedString: text)
            mutable.addAttribute(.paragraphStyle, value: paragraph,
                                 range: NSRange(location: 0, length: mutable.length))
            output.append(mutable)
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine

            // Fenced code blocks.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeFence {
                    let code = codeBuffer.joined(separator: "\n")
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = 8
                    paragraph.headIndent = 10
                    paragraph.firstLineHeadIndent = 10
                    let attributed = NSAttributedString(string: code + "\n", attributes: [
                        .font: monoFont,
                        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
                        .backgroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
                        .paragraphStyle: paragraph,
                    ])
                    output.append(attributed)
                    codeBuffer.removeAll()
                    inCodeFence = false
                } else {
                    inCodeFence = true
                }
                index += 1
                continue
            }

            if inCodeFence {
                codeBuffer.append(line)
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line.
            if trimmed.isEmpty {
                appendParagraph(NSAttributedString(string: "\n", attributes: [.font: bodyFont]), spacingAfter: 0)
                index += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                let rule = NSMutableParagraphStyle()
                rule.paragraphSpacing = 10
                output.append(NSAttributedString(string: "────────────────────────\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1),
                    .paragraphStyle: rule,
                ]))
                index += 1
                continue
            }

            // Headings.
            if let heading = headingLevel(trimmed) {
                let text = String(trimmed.dropFirst(heading.markerLength))
                    .trimmingCharacters(in: .whitespaces)
                let sizes: [CGFloat] = [baseFontSize + 11, baseFontSize + 8, baseFontSize + 5,
                                        baseFontSize + 3, baseFontSize + 1, baseFontSize]
                let size = sizes[min(heading.level - 1, sizes.count - 1)]
                let font = NSFont.boldSystemFont(ofSize: size)
                let attributed = inline(from: text, baseFont: font, baseSize: size)
                appendParagraph(attributed, spacingAfter: 8)
                index += 1
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoteLines.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 18
                paragraph.firstLineHeadIndent = 18
                paragraph.paragraphSpacing = 8
                let attributed = NSMutableAttributedString(
                    attributedString: inline(from: quoteLines.joined(separator: " "),
                                             baseFont: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                                             baseSize: baseFontSize))
                attributed.addAttribute(.foregroundColor,
                                        value: NSColor(calibratedWhite: 0.35, alpha: 1),
                                        range: NSRange(location: 0, length: attributed.length))
                attributed.addAttribute(.paragraphStyle, value: paragraph,
                                        range: NSRange(location: 0, length: attributed.length))
                output.append(attributed)
                continue
            }

            // Unordered list.
            if let item = unorderedListItem(trimmed) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 20
                paragraph.firstLineHeadIndent = 6
                paragraph.paragraphSpacing = 2
                let bullet = NSAttributedString(string: "•\t", attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1),
                ])
                let content = inline(from: item, baseFont: bodyFont, baseSize: baseFontSize)
                let combined = NSMutableAttributedString(attributedString: bullet)
                combined.append(content)
                combined.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                combined.addAttribute(.paragraphStyle, value: paragraph,
                                      range: NSRange(location: 0, length: combined.length))
                output.append(combined)
                index += 1
                continue
            }

            // Ordered list.
            if let (number, item) = orderedListItem(trimmed) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 24
                paragraph.firstLineHeadIndent = 6
                paragraph.paragraphSpacing = 2
                let marker = NSAttributedString(string: "\(number).\t", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: baseFontSize, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1),
                ])
                let content = inline(from: item, baseFont: bodyFont, baseSize: baseFontSize)
                let combined = NSMutableAttributedString(attributedString: marker)
                combined.append(content)
                combined.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                combined.addAttribute(.paragraphStyle, value: paragraph,
                                      range: NSRange(location: 0, length: combined.length))
                output.append(combined)
                index += 1
                continue
            }

            // Table (basic pipe syntax).
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|") else { break }
                    // Skip the alignment separator row.
                    let cells = candidate
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }) {
                        rows.append(cells)
                    }
                    index += 1
                }
                for (rowIndex, row) in rows.enumerated() {
                    let font = rowIndex == 0
                        ? NSFont.boldSystemFont(ofSize: baseFontSize)
                        : bodyFont
                    let line = row.joined(separator: "   │   ")
                    appendParagraph(inline(from: line, baseFont: font, baseSize: baseFontSize), spacingAfter: 3)
                }
                continue
            }

            // Plain paragraph.
            var paragraphLines: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || next.hasPrefix("#") || next.hasPrefix(">")
                    || next.hasPrefix("```") || next.hasPrefix("|")
                    || unorderedListItem(next) != nil || orderedListItem(next) != nil {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }
            appendParagraph(
                inline(from: paragraphLines.joined(separator: " "), baseFont: bodyFont, baseSize: baseFontSize),
                spacingAfter: 8)
        }

        // Unterminated code fence.
        if inCodeFence, !codeBuffer.isEmpty {
            output.append(NSAttributedString(string: codeBuffer.joined(separator: "\n"), attributes: [
                .font: monoFont,
            ]))
        }
        return output
    }

    private struct Heading {
        let level: Int
        let markerLength: Int
    }

    private static func headingLevel(_ line: String) -> Heading? {
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard count > 0, count <= 6, line.count > count else { return nil }
        let after = line.index(line.startIndex, offsetBy: count)
        guard line[after] == " " || line[after] == "\t" else { return nil }
        return Heading(level: count, markerLength: count)
    }

    private static func unorderedListItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> (Int, String)? {
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    /// Parse inline emphasis, code spans and links.
    static func inline(from text: String, baseFont: NSFont, baseSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let scalars = Array(text)
        var buffer = ""
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: [.font: baseFont]))
            buffer = ""
        }

        while index < scalars.count {
            let character = scalars[index]

            // Inline code.
            if character == "`" {
                if let end = findClosing(scalars, from: index + 1, marker: "`") {
                    flush()
                    let code = String(scalars[(index + 1)..<end])
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                        .backgroundColor: NSColor(calibratedWhite: 0.93, alpha: 1),
                    ]))
                    index = end + 1
                    continue
                }
            }

            // Bold / italic via ** or *.
            if character == "*" || character == "_" {
                let isDouble = index + 1 < scalars.count && scalars[index + 1] == character
                let marker = isDouble ? String(repeating: String(character), count: 2) : String(character)
                if let end = findClosing(scalars, from: index + marker.count, marker: marker) {
                    flush()
                    let content = String(scalars[(index + marker.count)..<end])
                    let descriptor = baseFont.fontDescriptor
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if isDouble { traits.insert(.bold) } else { traits.insert(.italic) }
                    let font = NSFont(descriptor: descriptor.withSymbolicTraits(traits), size: baseSize)
                        ?? baseFont
                    result.append(NSAttributedString(string: content, attributes: [.font: font]))
                    index = end + marker.count
                    continue
                }
            }

            // Links: [text](url)
            if character == "[" {
                if let closeBracket = findCharacter(scalars, from: index + 1, target: "]"),
                   closeBracket + 1 < scalars.count, scalars[closeBracket + 1] == "(",
                   let closeParen = findCharacter(scalars, from: closeBracket + 2, target: ")") {
                    flush()
                    let label = String(scalars[(index + 1)..<closeBracket])
                    let href = String(scalars[(closeBracket + 2)..<closeParen])
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                    if let url = URL(string: href) { attributes[.link] = url }
                    result.append(NSAttributedString(string: label, attributes: attributes))
                    index = closeParen + 1
                    continue
                }
            }

            // Images: ![alt](src) — keep the alt text, note the source.
            if character == "!", index + 1 < scalars.count, scalars[index + 1] == "[" {
                if let closeBracket = findCharacter(scalars, from: index + 2, target: "]"),
                   closeBracket + 1 < scalars.count, scalars[closeBracket + 1] == "(",
                   let closeParen = findCharacter(scalars, from: closeBracket + 2, target: ")") {
                    flush()
                    let alt = String(scalars[(index + 2)..<closeBracket])
                    let source = String(scalars[(closeBracket + 2)..<closeParen])
                    result.append(NSAttributedString(string: L("ui.image_alt_isempty_source_alt", alt.isEmpty ? source : alt), attributes: [
                        .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask),
                        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
                    ]))
                    index = closeParen + 1
                    continue
                }
            }

            buffer.append(character)
            index += 1
        }
        flush()
        return result
    }

    private static func findClosing(_ scalars: [Character], from: Int, marker: String) -> Int? {
        let markerChars = Array(marker)
        guard from < scalars.count else { return nil }
        var i = from
        while i <= scalars.count - markerChars.count {
            if Array(scalars[i..<(i + markerChars.count)]) == markerChars { return i }
            i += 1
        }
        return nil
    }

    private static func findCharacter(_ scalars: [Character], from: Int, target: Character) -> Int? {
        guard from < scalars.count else { return nil }
        var i = from
        var depth = 0
        while i < scalars.count {
            if scalars[i] == target, depth == 0 { return i }
            if scalars[i] == "(" { depth += 1 }
            if scalars[i] == ")" { depth -= 1 }
            i += 1
        }
        return nil
    }

    // MARK: - Attributed → Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        var output: [String] = []
        let full = attributed.string as NSString
        var location = 0

        while location < attributed.length {
            var range = NSRange()
            let attributes = attributed.attributes(at: location, effectiveRange: &range)
            let text = full.substring(with: range)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmed.isEmpty {
                output.append(renderParagraph(text, attributes: attributes, source: attributed, range: range))
            } else if !output.isEmpty && output.last != "" {
                output.append("")
            }
            location = range.location + range.length
        }

        return output.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderParagraph(
        _ text: String, attributes: [NSAttributedString.Key: Any],
        source: NSAttributedString, range: NSRange
    ) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "" }

        let font = attributes[.font] as? NSFont
        let traits = font?.fontDescriptor.symbolicTraits ?? []
        let size = font?.pointSize ?? 13
        let isBold = traits.contains(.bold)
        let isItalic = traits.contains(.italic)
        let isMono = font?.isFixedPitch ?? false

        // Headings inferred from relative font size.
        var prefix = ""
        if isBold || size > 14 {
            if size >= 24 { prefix = "# " }
            else if size >= 20 { prefix = "## " }
            else if size >= 17 { prefix = "### " }
            else if size >= 15 { prefix = "#### " }
            else if isBold && line.count < 60 { prefix = "**" ; }
        }

        // List detection via the paragraph style's text lists.
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
            if let list = style.textLists.first {
                let marker = list.markerFormat
                if marker == .decimal {
                    let counter = style.textLists.count
                    prefix = "1. "
                    _ = counter
                } else {
                    prefix = "- "
                }
                line = line.replacingOccurrences(of: "\t", with: " ")
            } else if style.headIndent > 14 && !style.textLists.isEmpty {
                prefix = "- "
            }
        }

        // Link handling: use the first link found in the range.
        if let link = attributes[.link] {
            let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if !href.isEmpty {
                return "\(prefix)[\(line)](\(href))"
            }
        }

        // Inline emphasis via font traits.
        let escaped = line
        if isMono {
            return "\(prefix)`\(escaped)`"
        }
        if isBold && isItalic {
            return "\(prefix)***\(escaped)***"
        }
        if isBold && prefix.isEmpty {
            return "**\(escaped)**"
        }
        if isItalic {
            return "\(prefix)*\(escaped)*"
        }
        return prefix + escaped
    }
}
