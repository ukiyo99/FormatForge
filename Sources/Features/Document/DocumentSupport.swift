import Foundation
import AppKit
import PDFKit
import CoreText
import UniformTypeIdentifiers

// MARK: - Document kinds

enum DocumentKind: String, CaseIterable, Identifiable, Sendable {
    case docx, doc, rtf, rtfd, odt, txt, md, html, pdf, webarchive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .docx: return "Word (.docx)"
        case .doc: return "Word 97 (.doc)"
        case .rtf: return "RTF"
        case .rtfd: return "RTFD"
        case .odt: return "OpenDocument"
        case .txt: return L("enum.document.docx")
        case .md: return "Markdown (.md)"
        case .html: return "HTML"
        case .pdf: return "PDF"
        case .webarchive: return "Web Archive"
        }
    }

    var fileExtension: String { rawValue }

    /// NSAttributedString document type, when one exists.
    var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        case .odt: return .openDocument
        case .html: return .html
        case .webarchive: return .webArchive
        case .txt, .md, .pdf: return nil
        }
    }

    static func from(extension ext: String) -> DocumentKind? {
        switch ext.lowercased() {
        case "docx": return .docx
        case "doc": return .doc
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "odt": return .odt
        case "txt", "text", "log", "csv", "json", "xml", "yml", "yaml": return .txt
        case "md", "markdown", "mdown": return .md
        case "html", "htm", "xhtml": return .html
        case "pdf": return .pdf
        case "webarchive": return .webarchive
        default: return nil
        }
    }
}

// MARK: - Support

enum DocumentSupport {

    // MARK: Reading

    static func load(_ url: URL, fontSize: CGFloat = 13) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()

        // Markdown gets our own parser.
        if ext == "md" || ext == "markdown" || ext == "mdown" {
            let text = try readText(url)
            return MarkdownConverter.attributed(from: text, baseFontSize: fontSize)
        }

        // PDF: extract the text layer page by page.
        if ext == "pdf" {
            return try loadPDF(url, fontSize: fontSize)
        }

        // Plain text.
        if ["txt", "text", "log", "csv", "json", "xml", "yml", "yaml"].contains(ext) {
            let text = try readText(url)
            return plainAttributed(text, fontSize: fontSize)
        }

        // Everything else goes through the system document readers.
        guard let kind = DocumentKind.from(extension: ext), let type = kind.documentType else {
            // Last resort: try to read it as text.
            let text = try readText(url)
            return plainAttributed(text, fontSize: fontSize)
        }

        var attributes: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if type == .html {
            attributes[.textEncodingName] = "utf-8"
        }

        do {
            return try NSAttributedString(
                url: url, options: attributes, documentAttributes: nil)
        } catch {
            // Fall back to textutil for formats the system reader rejects.
            if let text = TextUtil.convertToText(url) {
                return plainAttributed(text, fontSize: fontSize)
            }
            throw ProcessError.failed(
                code: 0,
                message: L("ui.could_not_read_the_document_url_lastpathco", url.lastPathComponent, error.localizedDescription))
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let gb = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) { return gb }
        if let latin = String(data: data, encoding: .isoLatin1) { return latin }
        throw ProcessError.failed(code: 0, message: L("ui.could_not_decode_the_text_file_url_lastpat", url.lastPathComponent))
    }

    private static func plainAttributed(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.black,
        ])
    }

    private static func loadPDF(_ url: URL, fontSize: CGFloat) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_open_the_pdf_url_lastpathcompone", url.lastPathComponent))
        }
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.isEmpty {
                // PDF text often has hard wraps mid-sentence; join them back up.
                let cleaned = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "-\n", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    output.append(NSAttributedString(string: cleaned + "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize),
                        .paragraphStyle: paragraph,
                        .foregroundColor: NSColor.black,
                    ]))
                }
            }
            // Mark page boundaries so PDF → MD keeps some structure.
            if index < document.pageCount - 1 {
                output.append(NSAttributedString(string: "\n---\n\n", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.gray,
                ]))
            }
        }

        if output.length == 0 {
            // Scanned PDF with no text layer — say so instead of writing an empty file.
            throw ProcessError.failed(
                code: 0,
                message: L("ui.this_pdf_has_no_text_layer_it_may_be_a_sca"))
        }
        return output
    }

    // MARK: Writing

    static func write(_ attributed: NSAttributedString, to url: URL, kind: DocumentKind,
                      pdfPageSize: CGSize = CGSize(width: 595, height: 842),
                      pdfMargin: CGFloat = 56) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch kind {
        case .md:
            let markdown = MarkdownConverter.markdown(from: attributed)
            try markdown.write(to: url, atomically: true, encoding: .utf8)

        case .txt:
            let text = attributed.string
            try text.write(to: url, atomically: true, encoding: .utf8)

        case .pdf:
            let data = try pdfData(from: attributed, pageSize: pdfPageSize, margin: pdfMargin)
            try data.write(to: url, options: .atomic)

        default:
            guard let type = kind.documentType else {
                throw ProcessError.failed(code: 0, message: L("ui.writing_kind_label_is_not_supported", kind.label))
            }
            // Ensure there is at least one attribute run so writers behave.
            let content = attributed.length > 0
                ? attributed
                : NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 12)])

            do {
                let data = try content.data(
                    from: NSRange(location: 0, length: content.length),
                    documentAttributes: [.documentType: type])
                try data.write(to: url, options: .atomic)
            } catch {
                // textutil covers formats the native writer refuses.
                if let fallback = TextUtil.convert(attributed, to: kind, at: url) {
                    _ = fallback
                    return
                }
                throw ProcessError.failed(
                    code: 0,
                    message: L("ui.could_not_write_kind_label_error_localized", kind.label, error.localizedDescription))
            }
        }
    }

    /// Paginate an attributed string into PDF using Core Text.
    static func pdfData(from attributed: NSAttributedString, pageSize: CGSize,
                        margin: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_the_pdf_output"))
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_the_pdf_context"))
        }

        // Guarantee a visible font even for empty documents.
        let content: NSAttributedString
        if attributed.length == 0 {
            content = NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        } else {
            content = attributed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let textRect = mediaBox.insetBy(dx: margin, dy: margin)
        let total = content.length
        var start = 0
        var pages = 0

        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRangeMake(start, 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            pages += 1
            if visible.length <= 0 { break }
            start += visible.length
        } while start < total && pages < 5000

        context.closePDF()
        return data as Data
    }

    /// Write an attributed string to PDF via PDFKit, which preserves links.
    static func writePDF(_ attributed: NSAttributedString, to url: URL,
                         pageSize: CGSize = CGSize(width: 595, height: 842),
                         margin: CGFloat = 56) throws {
        let data = try pdfData(from: attributed, pageSize: pageSize, margin: margin)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - textutil bridge

/// Fallback conversions via the system `textutil` tool.
enum TextUtil {
    static var available: Bool { ProcessRunner.exists("textutil") }

    static func convertToText(_ url: URL) -> String? {
        guard available else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatForge/\(UUID().uuidString).txt")
        defer { FileIO.removeQuietly(scratch) }
        try? FileManager.default.createDirectory(
            at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try? runSync(["-convert", "txt", "-output", scratch.path, url.path])
        guard result == true, let text = try? String(contentsOf: scratch, encoding: .utf8)
        else { return nil }
        return text
    }

    static func convert(_ attributed: NSAttributedString, to kind: DocumentKind, at url: URL) -> URL? {
        guard available else { return nil }
        let format: String
        switch kind {
        case .docx, .doc: format = "docx"
        case .rtf: format = "rtf"
        case .rtfd: format = "rtfd"
        case .odt: format = "odt"
        case .html: format = "html"
        case .txt: format = "txt"
        default: return nil
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatForge/\(UUID().uuidString).\(format)")
        defer { FileIO.removeQuietly(scratch) }
        try? FileManager.default.createDirectory(
            at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Write an intermediate RTF, then let textutil transcode it.
        guard let rtf = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        else { return nil }

        let intermediate = scratch.deletingPathExtension().appendingPathExtension("rtf")
        try? rtf.write(to: intermediate)
        guard (try? runSync(["-convert", format, "-output", scratch.path, intermediate.path])) == true,
              FileManager.default.fileExists(atPath: scratch.path)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: scratch, to: url)
        return url
    }

    /// textutil is short-lived, so a semaphore is acceptable here.
    private static func runSync(_ arguments: [String]) throws -> Bool {
        guard let path = ProcessRunner.locate("textutil") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
