import Foundation
import AppKit
import CoreGraphics
import CoreText

/// Renders text into a transparent PNG so overlays can be composited by
/// ffmpeg's `overlay` filter.
///
/// This build of ffmpeg has no `drawtext` (it requires libfreetype, which is
/// not compiled in), so text watermarks are rasterised natively instead. That
/// also gives us full CJK support, real font selection and crisp antialiasing.
enum TextRenderer {

    struct Style {
        var text: String
        var fontSize: Double
        var color: NSColor
        var opacity: Double = 1
        var bold: Bool = true
        /// Extra padding around the glyphs, in pixels.
        var padding: Double = 8

        var font: NSFont {
            let size = CGFloat(max(fontSize, 4))
            // PingFang covers Chinese, Japanese and Korean glyphs; fall back to
            // the system font when it is unavailable.
            if let cjk = NSFont(name: "PingFang SC", size: size) {
                return bold
                    ? NSFontManager.shared.convert(cjk, toHaveTrait: .boldFontMask)
                    : cjk
            }
            return bold
                ? NSFont.boldSystemFont(ofSize: size)
                : NSFont.systemFont(ofSize: size)
        }
    }

    /// Draw `style.text` into a PNG and return its URL plus pixel size.
    /// The returned image is cropped tightly to the text bounds.
    static func renderPNG(_ style: Style, in directory: URL) throws -> (url: URL, size: CGSize) {
        let attributed = NSAttributedString(string: style.text, attributes: [
            .font: style.font,
            .foregroundColor: style.color.withAlphaComponent(style.opacity),
        ])

        let line = CTLineCreateWithAttributedString(attributed)
        // useOpticalBounds trims the font's built-in leading/descender padding.
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else {
            throw ProcessError.failed(code: 0, message: L("ui.the_watermark_text_is_empty"))
        }

        let pad = style.padding
        let width = Int(ceil(bounds.width + pad * 2))
        let height = Int(ceil(bounds.height + pad * 2))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_the_text_canvas"))
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        // Start from a fully transparent canvas.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Position the baseline so the glyph box lands inside the padding.
        context.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_render_the_text"))
        }

        let url = directory.appendingPathComponent("text-\(UUID().uuidString).png")
        try ImageSupport.write(image, to: url, codec: .png)
        return (url, CGSize(width: width, height: height))
    }

    /// Build the overlay expression that pins a box of `size` at `position`.
    static func overlayPosition(
        _ position: String,
        size: CGSize,
        margin: Int
    ) -> (x: String, y: String) {
        let w = Int(size.width), h = Int(size.height)
        switch position {
        case "topLeft": return ("\(margin)", "\(margin)")
        case "topRight": return ("main_w-\(w)-\(margin)", "\(margin)")
        case "bottomLeft": return ("\(margin)", "main_h-\(h)-\(margin)")
        case "center": return ("(main_w-\(w))/2", "(main_h-\(h))/2")
        default: return ("main_w-\(w)-\(margin)", "main_h-\(h)-\(margin)")
        }
    }
}
