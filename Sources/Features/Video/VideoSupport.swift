import Foundation

/// Shared plumbing for the video tools.
enum VideoSupport {

    /// Duration used as the progress denominator, resolved lazily per input.
    static func duration(_ context: ToolContext) async -> Double {
        guard let input = context.firstInput else { return 0 }
        return await MediaProbe.duration(input)
    }

    /// Run ffmpeg and normalise the produced file into place.
    ///
    /// `inputArguments` overrides the default single-input preamble. Tools that
    /// need several inputs (concat lists, overlays, slideshows) must supply
    /// their own, otherwise the extra `-i` would shift every input index.
    static func encode(
        _ context: ToolContext,
        input: URL,
        output: URL,
        arguments: [String],
        duration: Double,
        inputArguments: [String]? = nil
    ) async throws -> URL {
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".ff-\(UUID().uuidString).\(output.pathExtension)")
        defer { FileIO.removeQuietly(temp) }

        var args = inputArguments ?? ["-i", input.path]
        args += arguments
        // Image outputs are handled by the image2 muxer, which ffmpeg selects
        // from the extension; forcing a codec name here would break them.
        if let hint = formatHint(for: output) {
            args += ["-f", hint]
        }
        args += [temp.path]

        _ = try await FFmpeg.execute(context: context, arguments: args, duration: duration, output: temp)

        guard let committed = try FileIO.commit(temp, to: output, policy: context.settings.conflictPolicy) else {
            return output
        }
        return committed
    }

    /// Explicit muxer hint keeps ambiguous extensions (e.g. `.m4a`) correct.
    /// Returns nil for image outputs so ffmpeg can pick the image2 muxer.
    static func formatHint(for output: URL) -> String? {
        switch output.pathExtension.lowercased() {
        case "mp4", "m4v": return "mp4"
        case "mov": return "mov"
        case "mkv": return "matroska"
        case "webm": return "webm"
        case "avi": return "avi"
        case "gif": return "gif"
        case "mp3": return "mp3"
        case "m4a": return "ipod"
        case "wav": return "wav"
        case "flac": return "flac"
        case "opus": return "opus"
        case "aac": return "adts"
        case "ts": return "mpegts"
        default:
            // Images (png/jpg/webp/...) let ffmpeg infer the muxer.
            return nil
        }
    }

    /// Container extension implied by the chosen codec + user preference.
    static func container(for codec: VideoCodec, requested: String) -> String {
        requested.isEmpty ? codec.preferredExtension : requested
    }

    /// Common quality/encoder fragment derived from the parameter set.
    static func qualityArguments(_ context: ToolContext, codec: VideoCodec) -> [String] {
        let crf = context.double("crf", codec.defaultCRF)
        let hardware = context.bool("hardware", context.settings.useHardwareAcceleration)
        let preset = context.string("preset", "")
        return FFmpeg.videoArgs(
            codec: codec,
            quality: crf,
            hardware: hardware,
            preset: preset.isEmpty ? nil : preset
        )
    }

    /// Append scale/fps fragments when the user asked for them.
    static func geometryArguments(_ context: ToolContext) -> [String] {
        var filters: [String] = []
        let scale = ScalePreset(rawValue: context.choice("scale", "original")) ?? .original

        switch scale {
        case .custom:
            let width = context.int("customWidth", 1280)
            if width > 0 { filters.append("scale=\(width):-2") }
        case .original:
            break
        default:
            if let height = scale.height {
                // Only downscale; upscaling by accident is almost never wanted.
                filters.append("scale=-2:min(\(height)\\,ih)")
            }
        }

        let fps = context.double("fps", 0)
        if fps > 0 { filters.append("fps=\(fmt(fps))") }

        return filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]
    }

    static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    /// Result list capped so a 5000-frame export does not flood the UI.
    static func summarise(_ urls: [URL], limit: Int = 24) -> [URL] {
        urls.count <= limit ? urls : Array(urls.prefix(limit))
    }

    /// Files matching a numbered sequence prefix, sorted naturally.
    static func sequence(in directory: URL, prefix: String) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Shared option builders

enum VideoOptions {
    static var codecs: [PickerOption] {
        VideoCodec.allCases.map { PickerOption($0.rawValue, $0.label, detail: $0.detail) }
    }

    static var scale: [PickerOption] { ScalePreset.allCases.map { PickerOption($0.rawValue, $0.label) } }

    static var audio: [PickerOption] { [
        .init("aac", "AAC"), .init("mp3", "MP3"), .init("opus", "Opus"),
        .init("flac", "FLAC"), .init("copy", L("ui.copy")), .init("none", L("enum.audio.aac.5")),
    ] }

    static var x264Presets: [PickerOption] { [
        .init("ultrafast", L("enum.codec.h264.34")), .init("veryfast", L("enum.codec.h264.34")), .init("fast", L("enum.codec.h264.18")),
        .init("medium", L("preset.balanced.label")), .init("slow", L("ui.slow")), .init("slower", L("enum.codec.h264.26")),
    ] }

    static func qualityParameters(defaultCRF: Double = 23, range: ClosedRange<Double> = 0...51) -> [ToolParameter] {
        [
            .slider("crf", L("video.fromimages.param.crf.label"), default: defaultCRF, min: range.lowerBound, max: range.upperBound, step: 1,
                    hint: L("ui.lower_values_mean_better_quality_and_large")),
            .picker("preset", L("enum.codec.h264.17"), default: "medium", options: x264Presets,
                    hint: L("ui.a_slower_preset_compresses_more_at_the_sam")),
            .toggle("hardware", L("ui.use_hardware_acceleration_videotoolbox"), default: false,
                    hint: L("ui.faster_encoding_but_noticeably_larger_file_2")),
        ]
    }
}
