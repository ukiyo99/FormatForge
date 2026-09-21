import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - Image inspector

/// Full image metadata: geometry, colour, EXIF, GPS, TIFF, IPTC and more.
struct ImageInspector: FileInspector {
    func inspect(
        inputs: [URL],
        values: [String: ParameterValue],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> InspectionReport {
        var sections: [InspectionReport.Section] = []

        for (index, url) in inputs.enumerated() {
            progress(Double(index) / Double(max(inputs.count, 1)))

            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                sections.append(.init(id: url.path, title: url.lastPathComponent,
                                      symbol: "xmark.circle", rows: [],
                                      note: L("ui.cannot_read_this_image")))
                continue
            }

            let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                              as? [CFString: Any]) ?? [:]
            let type = CGImageSourceGetType(source) as String?
            let count = CGImageSourceGetCount(source)

            var fileRows: [InspectionReport.Row] = [
                .init(id: "name", label: L("ui.file_name"), value: url.lastPathComponent),
                .init(id: "size", label: L("ui.file_size"),
                      value: Format.bytes(FileIO.size(of: url)), mono: true),
                .init(id: "type", label: L("ui.format"),
                      value: type.flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() }
                          ?? url.pathExtension.uppercased()),
            ]
            if count > 1 {
                fileRows.append(.init(id: "frames", label: L("ui.frame_count"), value: "\(count)", mono: true))
            }
            if let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) {
                fileRows.append(.init(id: "created", label: L("ui.created"),
                                      value: Self.dateFormatter.string(from: created)))
            }
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) {
                fileRows.append(.init(id: "modified", label: L("ui.modified"),
                                      value: Self.dateFormatter.string(from: modified)))
            }
            sections.append(.init(id: "file-\(url.path)", title: L("ui.file"), symbol: "doc",
                                  rows: fileRows))

            // ---- Geometry ----
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            var geometry: [InspectionReport.Row] = []
            if width > 0, height > 0 {
                geometry.append(.init(id: "size", label: L("ui.pixel_dimensions"),
                                      value: "\(width) × \(height)", mono: true))
                geometry.append(.init(id: "pixels", label: L("ui.total_pixels"),
                                      value: Format.pixels(width * height), mono: true))
                geometry.append(.init(id: "aspect", label: L("ui.aspect_ratio"),
                                      value: Format.aspect(width: CGFloat(width),
                                                           height: CGFloat(height)),
                                      mono: true))
                geometry.append(.init(id: "mp", label: L("ui.megapixels"),
                                      value: String(format: "%.1f MP",
                                                    Double(width * height) / 1_000_000),
                                      mono: true))
            }
            if let dpiW = properties[kCGImagePropertyDPIWidth] as? Double {
                let dpiH = properties[kCGImagePropertyDPIHeight] as? Double ?? dpiW
                geometry.append(.init(id: "dpi", label: L("ui.dimensions"),
                                      value: String(format: "%.0f × %.0f DPI", dpiW, dpiH),
                                      mono: true))
                // Physical print size at that DPI.
                if width > 0, dpiW > 0 {
                    let inchesW = Double(width) / dpiW
                    let inchesH = Double(height) / dpiH
                    geometry.append(.init(
                        id: "physical", label: L("ui.print_size"),
                        value: String(format: L("ui.1f_1f_in_1f_1f_cm"),
                                      inchesW, inchesH, inchesW * 2.54, inchesH * 2.54),
                        mono: true))
                }
            }
            if let orientation = properties[kCGImagePropertyOrientation] as? UInt32 {
                geometry.append(.init(id: "orientation", label: L("image.topdf.param.orientation.label"),
                                      value: Self.orientationName(orientation), mono: true))
            }
            if !geometry.isEmpty {
                sections.append(.init(id: "geometry-\(url.path)", title: L("ui.dimensions_and_resolution"),
                                      symbol: "ruler", rows: geometry))
            }

            // ---- Colour ----
            var color: [InspectionReport.Row] = []
            if let model = properties[kCGImagePropertyColorModel] as? String {
                color.append(.init(id: "model", label: L("ui.colour_model"),
                                   value: Self.colorModelName(model)))
            }
            if let depth = properties[kCGImagePropertyDepth] as? Int {
                color.append(.init(id: "depth", label: L("ui.bit_depth"), value: "\(depth) bit", mono: true))
            }
            if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool {
                color.append(.init(id: "alpha", label: L("ui.transparency"),
                                   value: hasAlpha ? L("ui.yes") : L("enum.transition.none"),
                                   status: hasAlpha ? .ok : nil))
            }
            if let profile = properties[kCGImagePropertyProfileName] as? String {
                color.append(.init(id: "profile", label: L("ui.color_profile"), value: profile))
            }
            if let isFloat = properties[kCGImagePropertyIsFloat] as? Bool, isFloat {
                color.append(.init(id: "float", label: L("ui.floating_point_samples"), value: L("ui.yes")))
            }
            if let isIndexed = properties[kCGImagePropertyIsIndexed] as? Bool, isIndexed {
                color.append(.init(id: "indexed", label: L("ui.indexed_color"), value: L("ui.yes")))
            }
            // GIF/PNG palette size.
            if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
               let palette = gif[kCGImagePropertyGIFHasGlobalColorMap] as? Bool {
                color.append(.init(id: "gifpalette", label: L("ui.global_palette"),
                                   value: palette ? L("ui.yes") : L("enum.transition.none")))
            }
            if !color.isEmpty {
                sections.append(.init(id: "color-\(url.path)", title: L("ui.color"),
                                      symbol: "paintpalette", rows: color))
            }

            // ---- EXIF ----
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var rows: [InspectionReport.Row] = []
                func add(_ id: String, _ label: String, _ value: String?, mono: Bool = false) {
                    guard let value, !value.isEmpty else { return }
                    rows.append(.init(id: id, label: label, value: value, mono: mono))
                }
                add("make", L("ui.make"), exif[kCGImagePropertyExifLensMake] as? String)
                add("lens", L("ui.lens"), exif[kCGImagePropertyExifLensModel] as? String)
                if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
                    let text = exposure >= 1
                        ? String(format: L("ui.1f_s"), exposure)
                        : String(format: L("ui.1_0f_s"), 1 / max(exposure, 0.00001))
                    add("exposure", L("ui.shutter_speed"), text)
                }
                if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                    add("aperture", L("ui.aperture"), String(format: "f/%.1f", fNumber))
                }
                if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
                   let first = iso.first {
                    add("iso", "ISO", "\(first)")
                }
                if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                    add("focal", L("ui.focal_length"), String(format: "%.0f mm", focal))
                }
                if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                    add("focal35", L("ui.35mm_equivalent"), "\(focal35) mm")
                }
                if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
                    add("bias", L("ui.exposure_compensation"), String(format: "%+.1f EV", bias))
                }
                if let program = exif[kCGImagePropertyExifExposureProgram] as? Int {
                    add("program", L("ui.exposure_program"), Self.exposureProgramName(program))
                }
                if let metering = exif[kCGImagePropertyExifMeteringMode] as? Int {
                    add("metering", L("ui.metering_mode"), Self.meteringName(metering))
                }
                if let flash = exif[kCGImagePropertyExifFlash] as? Int {
                    add("flash", L("ui.flash"), (flash & 1) != 0 ? L("ui.fired") : L("ui.did_not_fire"))
                }
                if let dateTime = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    add("taken", L("ui.date_taken"), dateTime)
                }
                if let w = exif[kCGImagePropertyExifPixelXDimension] as? Int,
                   let h = exif[kCGImagePropertyExifPixelYDimension] as? Int {
                    add("exifdims", L("ui.exif_dimensions"), "\(w) × \(h)", mono: true)
                }
                if !rows.isEmpty {
                    sections.append(.init(id: "exif-\(url.path)", title: L("ui.capture_settings"),
                                          symbol: "camera", rows: rows))
                }
            }

            // ---- TIFF ----
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                var rows: [InspectionReport.Row] = []
                func add(_ id: String, _ label: String, _ value: String?) {
                    guard let value, !value.isEmpty else { return }
                    rows.append(.init(id: id, label: label, value: value))
                }
                add("make", L("ui.camera_make"), tiff[kCGImagePropertyTIFFMake] as? String)
                add("model", L("ui.camera_model"), tiff[kCGImagePropertyTIFFModel] as? String)
                add("software", L("ui.software"), tiff[kCGImagePropertyTIFFSoftware] as? String)
                add("artist", L("ui.author"), tiff[kCGImagePropertyTIFFArtist] as? String)
                add("copyright", L("ui.copyright"), tiff[kCGImagePropertyTIFFCopyright] as? String)
                add("desc", L("ui.description"), tiff[kCGImagePropertyTIFFImageDescription] as? String)
                if let res = tiff[kCGImagePropertyTIFFXResolution] as? Double {
                    add("xres", L("ui.x_resolution"), String(format: "%.0f", res))
                }
                if let unit = tiff[kCGImagePropertyTIFFResolutionUnit] as? Int {
                    add("unit", L("ui.resolution_unit"), unit == 3 ? L("ui.centimeters") : L("ui.inches"))
                }
                if !rows.isEmpty {
                    sections.append(.init(id: "tiff-\(url.path)", title: L("ui.image_information"),
                                          symbol: "camera.viewfinder", rows: rows))
                }
            }

            // ---- GPS ----
            if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                var rows: [InspectionReport.Row] = []
                if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
                   let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
                    rows.append(.init(id: "lat", label: L("ui.latitude"),
                                      value: String(format: "%.6f° %@", lat, latRef), mono: true))
                }
                if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
                   let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                    rows.append(.init(id: "lon", label: L("ui.longitude"),
                                      value: String(format: "%.6f° %@", lon, lonRef), mono: true))
                }
                if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                    rows.append(.init(id: "alt", label: L("ui.altitude"),
                                      value: String(format: "%.1f m", alt), mono: true))
                }
                if let date = gps[kCGImagePropertyGPSDateStamp] as? String {
                    rows.append(.init(id: "gpsdate", label: L("ui.gps_date"), value: date, mono: true))
                }
                if !rows.isEmpty {
                    sections.append(.init(id: "gps-\(url.path)", title: L("ui.location"),
                                          symbol: "location", rows: rows))
                }
            }

            // ---- Dominant colours ----
            if values["extractPalette"]?.boolValue ?? true,
               let palette = ImageInfoTool.dominantColors(url, count: 6) {
                let rows = palette.enumerated().map { index, hex in
                    InspectionReport.Row(id: "c\(index)", label: L("ui.color_index_1", index + 1),
                                         value: hex, mono: true, copyable: true)
                }
                sections.append(.init(id: "palette-\(url.path)", title: L("ui.dominant_colors"),
                                      symbol: "paintbrush", rows: rows))
            }

            // ---- Embedded preview / thumbnail presence ----
            var extra: [InspectionReport.Row] = []
            if CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
            ] as CFDictionary) != nil {
                extra.append(.init(id: "thumb", label: L("ui.thumbnail_available"), value: L("ui.yes"), status: .ok))
            }
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               exif[kCGImagePropertyExifDateTimeOriginal] == nil {
                extra.append(.init(id: "nodate", label: L("ui.date_taken"), value: L("ui.not_recorded")))
            }
            if !extra.isEmpty {
                sections.append(.init(id: "extra-\(url.path)", title: L("ui.other"),
                                      symbol: "ellipsis.circle", rows: extra))
            }
        }

        progress(1)
        let summary = L("ui.inputs_count_files", inputs.count)
        return InspectionReport(sections: sections, summary: summary)
    }

    // MARK: Naming helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func orientationName(_ value: UInt32) -> String {
        switch value {
        case 1: return L("ui.normal_1")
        case 2: return L("ui.flip_horizontal_2")
        case 3: return L("ui.rotate_180_3")
        case 4: return L("ui.flip_vertical_4")
        case 5: return L("ui.transpose_5")
        case 6: return L("ui.rotate_90_clockwise_6")
        case 7: return L("ui.transverse_7")
        case 8: return L("ui.rotate_90_counterclockwise_8")
        default: return "\(value)"
        }
    }

    static func colorModelName(_ model: String) -> String {
        switch model {
        case "RGB": return L("ui.rgb_true_color")
        case "Gray": return L("ui.grayscale")
        case "CMYK": return L("ui.cmyk")
        case "Lab": return "Lab"
        case "Indexed": return L("ui.indexed_color")
        default: return model
        }
    }

    static func exposureProgramName(_ value: Int) -> String {
        switch value {
        case 0: return L("ui.undefined")
        case 1: return L("ui.manual")
        case 2: return L("ui.program_auto")
        case 3: return L("ui.aperture_priority")
        case 4: return L("ui.shutter_priority")
        case 5: return L("ui.creative_program")
        case 6: return L("ui.action_program")
        case 7: return L("ui.portrait_mode")
        case 8: return L("ui.landscape_mode")
        default: return "\(value)"
        }
    }

    static func meteringName(_ value: Int) -> String {
        switch value {
        case 0: return L("ui.unknown")
        case 1: return L("ui.average")
        case 2: return L("ui.center_weighted")
        case 3: return L("ui.spot")
        case 4: return L("ui.multi_spot")
        case 5: return L("ui.evaluative")
        case 6: return L("ui.partial")
        default: return "\(value)"
        }
    }
}
