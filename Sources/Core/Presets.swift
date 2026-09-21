import Foundation

// MARK: - Preset

/// A named bundle of parameter values that replaces the manual "pick every
/// option yourself" flow. Every tool ships with a sensible default preset so
/// the common case is one click.
struct ToolPreset: Identifiable, Sendable {
    let id: String
    let label: String
    /// Symbol used in the picker.
    var symbol: String = "wand.and.stars"
    /// One-line explanation of the trade-off, shown as a hint.
    let detail: String
    /// Values applied on top of the tool defaults. A key mapped to `nil`
    /// removes the parameter, letting the tool fall back to its own default.
    var values: [String: ParameterValue]

    init(id: String, label: String, symbol: String = "wand.and.stars",
         detail: String, values: [String: ParameterValue]) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.detail = detail
        self.values = values
    }
}

// MARK: - Preset catalogue

/// Built-in templates, grouped by the kind of trade-off they express.
enum Presets {

    // MARK: Video quality ladders

    /// Reusable video quality ladder shared by every video encoder tool.
    static func videoQuality(_ kind: Kind) -> ToolPreset {
        switch kind {
        case .lossless:
            return ToolPreset(
                id: "lossless", label: L("ui.quality_first"), symbol: "sparkles",
                detail: L("ui.nearly_lossless_size_drops_slightly_or_sta"),
                values: ["crf": .number(17), "preset": .text("slow"), "hardware": .bool(false)])
        case .balanced:
            return ToolPreset(
                id: "balanced", label: L("ui.balanced_recommended"), symbol: "scale.3d",
                detail: L("ui.visually_indistinguishable_about_half_the"),
                values: ["crf": .number(23), "preset": .text("medium"), "hardware": .bool(false)])
        case .compact:
            return ToolPreset(
                id: "compact", label: L("ui.size_first"), symbol: "arrow.down.right.and.arrow.up.left",
                detail: L("ui.noticeably_smaller_with_slight_quality_los"),
                values: ["crf": .number(28), "preset": .text("medium"), "hardware": .bool(false)])
        case .extreme:
            return ToolPreset(
                id: "extreme", label: L("ui.maximum_compression"), symbol: "arrow.down.to.line",
                detail: L("ui.smallest_size_for_chat_sharing_quality_los"),
                values: ["crf": .number(33), "preset": .text("slow"), "hardware": .bool(false)])
        case .fast:
            return ToolPreset(
                id: "fast", label: L("ui.fastest_processing"), symbol: "bolt.fill",
                detail: L("ui.hardware_encoding_much_faster_slightly_low"),
                values: ["crf": .number(23), "preset": .text("veryfast"), "hardware": .bool(true)])
        case .custom:
            return ToolPreset(
                id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                detail: L("ui.adjust_all_parameters_below_manually"), values: [:])
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case lossless, balanced, compact, extreme, fast, custom
    }

    /// The standard ladder used by compression-style tools.
    static var videoLadder: [ToolPreset] {
        [videoQuality(.balanced), videoQuality(.compact), videoQuality(.lossless),
         videoQuality(.extreme), videoQuality(.fast), videoQuality(.custom)]
    }

    // MARK: Resolution ladders

    /// Common social/device targets expressed as a size + fit combination.
    static func resolution(_ id: String) -> ToolPreset? {
        switch id {
        case "keep":
            return ToolPreset(id: id, label: L("enum.kind.lossless"), symbol: "arrow.triangle.2.circlepath",
                              detail: L("ui.leave_resolution_unchanged"), values: ["scale": .text("original")])
        case "1080p":
            return ToolPreset(id: id, label: L("enum.kind.lossless.2"), symbol: "tv",
                              detail: L("ui.up_to_1920_1080_the_most_versatile"),
                              values: ["scale": .text("p1080")])
        case "720p":
            return ToolPreset(id: id, label: L("enum.kind.lossless.3"), symbol: "tv",
                              detail: L("ui.up_to_1280_720_much_smaller_files"),
                              values: ["scale": .text("p720")])
        case "480p":
            return ToolPreset(id: id, label: L("enum.kind.lossless.4"), symbol: "tv",
                              detail: L("ui.good_for_chat_apps_and_older_devices"),
                              values: ["scale": .text("p480")])
        case "wechat":
            return ToolPreset(id: id, label: L("enum.kind.lossless.5"), symbol: "bubble.left.and.bubble.right",
                              detail: L("ui.720p_size_first_kept_within_sending_limits"),
                              values: ["scale": .text("p720"), "crf": .number(28)])
        case "web":
            return ToolPreset(id: id, label: L("enum.kind.lossless.6"), symbol: "globe",
                              detail: L("ui.1080p_balanced_for_clarity_and_fast_loadin"),
                              values: ["scale": .text("p1080"), "crf": .number(24)])
        default:
            return nil
        }
    }

    static var resolutionLadder: [ToolPreset] {
        ["keep", "1080p", "720p", "480p", "wechat", "web"].compactMap(resolution)
    }

    // MARK: Image quality ladders

    static func imageQuality(_ kind: Kind) -> ToolPreset {
        switch kind {
        case .lossless:
            return ToolPreset(id: "lossless", label: L("ui.quality_first"), symbol: "sparkles",
                              detail: L("preset.lossless.detail"),
                              values: ["quality": .number(95)])
        case .balanced:
            return ToolPreset(id: "balanced", label: L("ui.balanced_recommended"), symbol: "scale.3d",
                              detail: L("preset.balanced.detail"),
                              values: ["quality": .number(80)])
        case .compact:
            return ToolPreset(id: "compact", label: L("ui.size_first"), symbol: "arrow.down.right.and.arrow.up.left",
                              detail: L("preset.compact.detail"),
                              values: ["quality": .number(65)])
        case .extreme:
            return ToolPreset(id: "extreme", label: L("ui.maximum_compression"), symbol: "arrow.down.to.line",
                              detail: L("preset.extreme.detail"),
                              values: ["quality": .number(45)])
        case .fast:
            return ToolPreset(id: "fast", label: L("ui.fastest_processing"), symbol: "bolt.fill",
                              detail: L("preset.fast.detail"),
                              values: ["quality": .number(78), "compression": .number(20)])
        case .custom:
            return ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                              detail: L("ui.adjust_all_parameters_below_manually"), values: [:])
        }
    }

    static var imageLadder: [ToolPreset] {
        [imageQuality(.balanced), imageQuality(.compact), imageQuality(.lossless),
         imageQuality(.extreme), imageQuality(.custom)]
    }

    /// Size targets for image compression, expressed in kilobytes.
    static var imageSizeTargets: [ToolPreset] {
        [
            ToolPreset(id: "avatar", label: L("preset.avatar.label"), symbol: "person.crop.circle",
                       detail: L("preset.avatar.detail"),
                       values: ["mode": .text("targetSize"), "targetKB": .number(100),
                                "resize": .text("maxWidth"), "maxWidth": .number(800)]),
            ToolPreset(id: "web", label: L("preset.web.label"), symbol: "globe",
                       detail: L("preset.web.detail"),
                       values: ["mode": .text("targetSize"), "targetKB": .number(300),
                                "resize": .text("maxWidth"), "maxWidth": .number(1600)]),
            ToolPreset(id: "email", label: L("preset.email.label"), symbol: "envelope",
                       detail: L("preset.email.detail"),
                       values: ["mode": .text("targetSize"), "targetKB": .number(500)]),
            ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                       detail: L("preset.custom.detail"), values: [:]),
        ]
    }

    // MARK: GIF ladders

    static var gifLadder: [ToolPreset] {
        [
            ToolPreset(id: "compact", label: L("preset.compact.label"), symbol: "arrow.down.right.and.arrow.up.left",
                       detail: L("preset.compact.detail.2"),
                       values: ["width": .number(480), "fps": .number(12),
                                "colors": .number(128), "highQuality": .bool(true)]),
            ToolPreset(id: "balanced", label: L("preset.balanced.label"), symbol: "scale.3d",
                       detail: L("preset.balanced.detail.2"),
                       values: ["width": .number(640), "fps": .number(15),
                                "colors": .number(256), "highQuality": .bool(true)]),
            ToolPreset(id: "quality", label: L("ui.quality_first"), symbol: "sparkles",
                       detail: L("preset.quality.detail"),
                       values: ["width": .number(800), "fps": .number(20),
                                "colors": .number(256), "highQuality": .bool(true),
                                "dither": .text("floyd_steinberg")]),
            ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                       detail: L("preset.custom.detail.2"), values: [:]),
        ]
    }

    // MARK: Archive ladders

    static var archiveLadder: [ToolPreset] {
        [
            ToolPreset(id: "balanced", label: L("ui.balanced_recommended"), symbol: "scale.3d",
                       detail: L("preset.balanced.detail.3"),
                       values: ["level": .number(5)]),
            ToolPreset(id: "max", label: L("preset.max.label"), symbol: "arrow.down.to.line",
                       detail: L("preset.max.detail"),
                       values: ["level": .number(9)]),
            ToolPreset(id: "fast", label: L("preset.fast.label"), symbol: "bolt.fill",
                       detail: L("preset.fast.detail.2"),
                       values: ["level": .number(1)]),
            ToolPreset(id: "store", label: L("preset.store.label"), symbol: "shippingbox",
                       detail: L("preset.store.detail"),
                       values: ["level": .number(0)]),
            ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                       detail: L("preset.custom.detail.3"), values: [:]),
        ]
    }

    // MARK: Document ladders

    static var documentLadder: [ToolPreset] {
        [
            ToolPreset(id: "balanced", label: L("preset.balanced.label.2"), symbol: "doc.text",
                       detail: L("preset.balanced.detail.4"),
                       values: ["fontSize": .number(13), "pdfPageSize": .text("a4"),
                                "pdfMargin": .number(56)]),
            ToolPreset(id: "compact", label: L("preset.compact.label.2"), symbol: "arrow.down.right.and.arrow.up.left",
                       detail: L("preset.compact.detail.3"),
                       values: ["fontSize": .number(11), "pdfPageSize": .text("a4"),
                                "pdfMargin": .number(36)]),
            ToolPreset(id: "reading", label: L("preset.reading.label"), symbol: "book",
                       detail: L("preset.reading.detail"),
                       values: ["fontSize": .number(15), "pdfPageSize": .text("a4"),
                                "pdfMargin": .number(72)]),
            ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                       detail: L("preset.custom.detail.4"), values: [:]),
        ]
    }

    // MARK: Lookup

    /// The preset ladder appropriate for a tool, or an empty list when the tool
    /// is simple enough not to need one.
    static func ladder(for toolID: String) -> [ToolPreset] {
        switch toolID {
        case "video.compress":
            return [videoQuality(.balanced), videoQuality(.compact), videoQuality(.extreme),
                    videoQuality(.lossless), videoQuality(.fast), videoQuality(.custom)]
        case "video.convert", "video.speed", "video.watermark", "video.concat":
            return [videoQuality(.balanced), videoQuality(.compact), videoQuality(.lossless),
                    videoQuality(.fast), videoQuality(.custom)]
        case "video.resize":
            return resolutionLadder
        case "video.gif":
            return gifLadder
        case "video.screenshot", "video.frames":
            return [
                ToolPreset(id: "balanced", label: L("preset.balanced.label.3"), symbol: "scale.3d",
                           detail: L("preset.balanced.detail.5"),
                           values: ["format": .text("png"), "scale": .text("original")]),
                ToolPreset(id: "compact", label: L("preset.compact.label.3"), symbol: "arrow.down.right.and.arrow.up.left",
                           detail: L("preset.compact.detail.4"),
                           values: ["format": .text("jpg"), "quality": .number(88),
                                    "scale": .text("p1080")]),
                ToolPreset(id: "thumb", label: L("preset.thumb.label"), symbol: "square.grid.2x2",
                           detail: L("preset.thumb.detail"),
                           values: ["format": .text("jpg"), "quality": .number(80),
                                    "scale": .text("p480")]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.5"), values: [:]),
            ]
        case "image.convert":
            return [
                ToolPreset(id: "web", label: L("preset.web.label.2"), symbol: "globe",
                           detail: L("preset.web.detail.2"),
                           values: ["codec": .text("jpeg"), "quality": .number(80),
                                    "resize": .text("maxWidth"), "maxWidth": .number(1920)]),
                ToolPreset(id: "retina", label: L("preset.retina.label"), symbol: "sparkles",
                           detail: L("preset.retina.detail"),
                           values: ["codec": .text("png"), "quality": .number(95)]),
                ToolPreset(id: "share", label: L("preset.share.label"), symbol: "bubble.left.and.bubble.right",
                           detail: L("preset.share.detail"),
                           values: ["codec": .text("jpeg"), "quality": .number(70),
                                    "resize": .text("maxWidth"), "maxWidth": .number(1280)]),
                ToolPreset(id: "modern", label: L("preset.modern.label"), symbol: "sparkles",
                           detail: L("preset.modern.detail"),
                           values: ["codec": .text("webp"), "quality": .number(80)]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.6"), values: [:]),
            ]
        case "image.compress":
            return imageLadder + imageSizeTargets
        case "image.resize":
            return [
                ToolPreset(id: "web", label: L("preset.web.label.3"), symbol: "globe",
                           detail: L("preset.web.detail.3"), values: ["mode": .text("longEdge"), "longEdge": .number(1920)]),
                ToolPreset(id: "retina", label: L("preset.retina.label.2"), symbol: "sparkles",
                           detail: L("preset.retina.detail.2"), values: ["mode": .text("longEdge"), "longEdge": .number(1440)]),
                ToolPreset(id: "half", label: L("preset.half.label"), symbol: "arrow.down.right.and.arrow.up.left",
                           detail: L("preset.half.detail"), values: ["mode": .text("percent"), "percent": .number(50)]),
                ToolPreset(id: "thumb", label: L("preset.thumb.label"), symbol: "square.grid.2x2",
                           detail: L("preset.thumb.detail.2"), values: ["mode": .text("longEdge"), "longEdge": .number(400)]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.7"), values: [:]),
            ]
        case "archive.create":
            return archiveLadder
        case "doc.word2pdf", "doc.md2pdf", "doc.txt2pdf", "doc.txt2word",
             "doc.md2word", "doc.word2md", "doc.word2txt", "doc.pdf2word", "doc.pdf2md":
            return documentLadder
        case "doc.pdfcompress":
            return [
                ToolPreset(id: "screen", label: L("preset.screen.label"), symbol: "display",
                           detail: L("preset.screen.detail"),
                           values: ["dpi": .number(110), "quality": .number(65)]),
                ToolPreset(id: "email", label: L("preset.email.label.2"), symbol: "envelope",
                           detail: L("preset.email.detail.2"),
                           values: ["dpi": .number(96), "quality": .number(55)]),
                ToolPreset(id: "print", label: L("preset.print.label"), symbol: "printer",
                           detail: L("preset.print.detail"),
                           values: ["dpi": .number(200), "quality": .number(85)]),
                ToolPreset(id: "gray", label: L("preset.gray.label"), symbol: "circle.lefthalf.filled",
                           detail: L("preset.gray.detail"),
                           values: ["dpi": .number(150), "quality": .number(70), "grayscale": .bool(true)]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.8"), values: [:]),
            ]
        case "doc.pdfsplit":
            return [
                ToolPreset(id: "each", label: L("preset.each.label"), symbol: "doc.on.doc",
                           detail: L("preset.each.detail"), values: ["mode": .text("each")]),
                ToolPreset(id: "ten", label: L("preset.ten.label"), symbol: "doc.on.doc",
                           detail: L("preset.ten.detail"), values: ["mode": .text("every"), "pagesPerFile": .number(10)]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.9"), values: [:]),
            ]
        case "doc.ocr":
            return [
                ToolPreset(id: "accurate", label: L("preset.accurate.label"), symbol: "text.viewfinder",
                           detail: L("preset.accurate.detail"),
                           values: ["language": .text("zh-Hans"), "level": .text("accurate"),
                                    "output": .text("txt")]),
                ToolPreset(id: "searchable", label: L("preset.searchable.label"), symbol: "doc.text.magnifyingglass",
                           detail: L("preset.searchable.detail"),
                           values: ["language": .text("zh-Hans"), "level": .text("accurate"),
                                    "output": .text("pdf")]),
                ToolPreset(id: "english", label: L("preset.english.label"), symbol: "textformat.abc",
                           detail: L("preset.english.detail"),
                           values: ["language": .text("en-US"), "level": .text("accurate"),
                                    "output": .text("txt")]),
                ToolPreset(id: "custom", label: L("ui.custom"), symbol: "slider.horizontal.3",
                           detail: L("preset.custom.detail.10"), values: [:]),
            ]
        default:
            return []
        }
    }
}
