import Foundation

// MARK: - 1. Screenshot

enum VideoScreenshotTool {
    static var tool: Tool { Tool(
        id: "video.screenshot",
        name: L("video.screenshot.name"),
        summary: L("video.screenshot.summary"),
        symbol: "camera",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts", "flv", "wmv"],
                requiresFFmpeg: true,
        actionTitle: L("video.screenshot.action"),
        parameters: [
            .picker("mode", L("video.screenshot.param.mode.label"), default: "single", options: [
                .init("single", L("video.screenshot.param.mode.label.2")), .init("interval", L("video.screenshot.param.mode.label.3")), .init("count", L("video.screenshot.param.mode.label.4")),
            ]),
            .number("timestamp", L("video.screenshot.param.timestamp.label"), default: 1, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .equals("mode", "single")),
            .number("interval", L("video.screenshot.param.interval.label"), default: 5, min: 0.05, max: 10_000, step: 0.5,
                    visibleWhen: .equals("mode", "interval")),
            .number("count", L("video.screenshot.param.count.label"), default: 9, min: 1, max: 500, step: 1,
                    visibleWhen: .equals("mode", "count")),
            .number("start", L("video.screenshot.param.start.label"), default: 0, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .notEquals("mode", "single")),
            .number("end", L("video.screenshot.param.end.label"), default: 0, min: 0, max: 100_000, step: 0.1,
                    hint: L("video.screenshot.param.end.hint"),
                    visibleWhen: .notEquals("mode", "single")),
            .picker("format", L("pdf.toimage.param.format.label"), default: "png", options: [
                .init("png", L("video.screenshot.param.format.label")), .init("jpg", L("video.screenshot.param.format.label.2")), .init("webp", "WebP"), .init("tiff", "TIFF"),
            ]),
            .slider("quality", L("video.screenshot.param.quality.label"), default: 92, min: 40, max: 100, step: 1,
                    visibleWhen: .equals("format", "jpg")),
            .picker("scale", L("video.screenshot.param.scale.label"), default: "original", options: VideoOptions.scale),
            .number("customWidth", L("video.screenshot.param.customWidth.label"), default: 1920, min: 16, max: 7680,
                    visibleWhen: .equals("scale", "custom")),
            .toggle("hardwareDecode", L("video.screenshot.param.hardwareDecode.label"), default: true),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let mode = context.choice("mode", "single")
                let format = context.choice("format", "png")
                let ext = format
                let scaleArgs = screenshotScale(context)

                // Hardware decoding noticeably speeds up 4K frame extraction.
                let hwaccel = context.bool("hardwareDecode", true)
                    ? ["-hwaccel", "videotoolbox"] : []

                if mode == "single" {
                    let output = context.output(index: index, ext: ext, suffix: L("video.screenshot.param.hardwareDecode.label.2"))
                    // Seek and hardware decoding are input options, so they must
                    // precede -i; seeking here also makes the read instant.
                    let inputArguments = hwaccel
                        + ["-ss", VideoSupport.fmt(context.double("timestamp", 1)), "-i", input.path]
                    var args = scaleArgs
                    args += ["-frames:v", "1", "-q:v", qualityValue(context, format)]
                    outputs.append(try await VideoSupport.encode(
                        context, input: input, output: output, arguments: args,
                        duration: 0, inputArguments: inputArguments))
                    continue
                }

                // Batch modes write a numbered sequence into a scratch folder.
                let scratch = try context.makeScratch()
                defer { FileIO.removeQuietly(scratch) }
                let base = input.deletingPathExtension().lastPathComponent
                let pattern = scratch.appendingPathComponent("\(base)_%04d.\(ext)").path

                var args: [String] = hwaccel
                let start = context.double("start", 0)
                let end = context.double("end", 0)
                if start > 0 { args += ["-ss", VideoSupport.fmt(start)] }
                if end > start { args += ["-to", VideoSupport.fmt(end)] }
                args += ["-i", input.path]

                if mode == "interval" {
                    let interval = max(context.double("interval", 5), 0.05)
                    args += ["-vf", "fps=1/\(VideoSupport.fmt(interval))\(scaleFilterSuffix(context))"]
                } else {
                    let count = max(context.int("count", 9), 1)
                    let window = end > start ? end - start : max(duration - start, 0)
                    let interval = window > 0 ? window / Double(count) : 1
                    args += ["-vf", "fps=1/\(VideoSupport.fmt(interval))\(scaleFilterSuffix(context))"]
                }
                args += ["-frames:v", mode == "interval" ? "100000" : "\(context.int("count", 9))"]
                args += ["-q:v", qualityValue(context, format)]
                args += [pattern]

                let result = try await ProcessRunner.run(
                    "ffmpeg", FFmpeg.baseFlags + args, handle: context.handle,
                    onStdout: FFmpeg.progressHandler(duration: duration, reporter: context.progress))
                if result.cancelled { throw ProcessError.cancelled }
                guard result.exitCode == 0 else {
                    throw ProcessError.failed(code: result.exitCode, message: result.stderr)
                }

                let frames = VideoSupport.sequence(in: scratch, prefix: "\(base)_")
                for (i, frame) in frames.enumerated() {
                    let target = context.output(
                        "\(base)_\(String(format: "%03d", i + 1)).\(ext)")
                    if let committed = try FileIO.commit(
                        frame, to: target, policy: context.settings.conflictPolicy) {
                        outputs.append(committed)
                    }
                }
            }
            return VideoSupport.summarise(outputs, limit: 60)
        }
    ) }

    private static func qualityValue(_ context: ToolContext, _ format: String) -> String {
        guard format == "jpg" else { return "2" }
        // ffmpeg qscale is inverted: 2 is best, 31 is worst.
        let quality = context.double("quality", 92)
        let q = Int(31 - (quality / 100) * 29)
        return "\(min(max(q, 2), 31))"
    }

    private static func screenshotScale(_ context: ToolContext) -> [String] {
        let suffix = scaleFilterSuffix(context)
        guard !suffix.isEmpty else { return [] }
        return ["-vf", String(suffix.dropFirst())]
    }

    /// Returns ",scale=..." (leading comma) so it can be appended to an fps filter.
    private static func scaleFilterSuffix(_ context: ToolContext) -> String {
        let scale = ScalePreset(rawValue: context.choice("scale", "original")) ?? .original
        switch scale {
        case .custom:
            let width = context.int("customWidth", 1920)
            return width > 0 ? ",scale=\(width):-2" : ""
        case .original:
            return ""
        default:
            guard let height = scale.height else { return "" }
            return ",scale=-2:min(\(height)\\,ih)"
        }
    }
}

// MARK: - 2. Frame export

enum VideoFrameExportTool {
    static var tool: Tool { Tool(
        id: "video.frames",
        name: L("video.frames.name"),
        summary: L("video.frames.summary"),
        symbol: "square.stack.3d.down.right",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts"],
                requiresFFmpeg: true,
        actionTitle: L("video.frames.action"),
        parameters: [
            .picker("mode", L("video.frames.param.mode.label"), default: "everyN", options: [
                .init("all", L("video.frames.param.mode.label.2")), .init("everyN", L("video.frames.param.mode.label.3")), .init("range", L("video.frames.param.mode.label.4")),
            ]),
            .number("step", L("video.frames.param.step.label"), default: 30, min: 1, max: 10_000, step: 1,
                    hint: L("video.frames.param.step.hint"),
                    visibleWhen: .equals("mode", "everyN")),
            .number("start", L("video.frames.param.start.label"), default: 0, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .equals("mode", "range")),
            .number("end", L("video.screenshot.param.end.label"), default: 10, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .equals("mode", "range")),
            .number("fps", L("video.frames.param.fps.label"), default: 0, min: 0, max: 240, step: 1,
                    hint: L("video.frames.param.fps.hint")),
            .picker("format", L("pdf.toimage.param.format.label"), default: "png", options: [
                .init("png", L("video.screenshot.param.format.label")), .init("jpg", "JPG"), .init("webp", "WebP"), .init("tiff", "TIFF"),
            ]),
            .slider("quality", L("video.screenshot.param.quality.label"), default: 95, min: 40, max: 100, step: 1,
                    visibleWhen: .equals("format", "jpg")),
            .picker("naming", L("video.frames.param.naming.label"), default: "index", options: [
                .init("index", L("video.frames.param.naming.label.2")), .init("timecode", L("video.frames.param.naming.label.3")),
            ]),
            .toggle("subfolder", L("video.frames.param.subfolder.label"), default: true),
            .number("maxFrames", L("video.frames.param.maxFrames.label"), default: 2000, min: 1, max: 200_000, step: 100,
                    hint: L("video.frames.param.maxFrames.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let info = await MediaProbe.info(for: input)
                let format = context.choice("format", "png")
                let base = input.deletingPathExtension().lastPathComponent

                let destination: URL
                if context.bool("subfolder", true) {
                    destination = context.outputDirectory
                        .appendingPathComponent("\(base)_frames", isDirectory: true)
                    try FileIO.ensureDirectory(destination)
                } else {
                    destination = context.outputDirectory
                }

                let scratch = try context.makeScratch()
                defer { FileIO.removeQuietly(scratch) }
                let pattern = scratch.appendingPathComponent("f_%06d.\(format)").path

                var args: [String] = []
                let mode = context.choice("mode", "everyN")
                if mode == "range" {
                    args += ["-ss", VideoSupport.fmt(context.double("start", 0))]
                    args += ["-to", VideoSupport.fmt(context.double("end", 10))]
                }
                args += ["-i", input.path]

                var filters: [String] = []
                let fps = context.double("fps", 0)
                if fps > 0 {
                    filters.append("fps=\(VideoSupport.fmt(fps))")
                } else if mode == "everyN" {
                    let step = max(context.int("step", 30), 1)
                    filters.append("select=not(mod(n\\,\(step)))")
                    filters.append("setpts=N/FRAME_RATE/TB")
                }
                if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }

                if format == "jpg" {
                    let q = Int(31 - (context.double("quality", 95) / 100) * 29)
                    args += ["-q:v", "\(min(max(q, 2), 31))"]
                } else if format == "png" {
                    args += ["-compression_level", "3"]
                }
                args += ["-frames:v", "\(context.int("maxFrames", 2000))"]
                args += [pattern]

                let result = try await ProcessRunner.run(
                    "ffmpeg", FFmpeg.baseFlags + ["-progress", "pipe:1"] + args,
                    handle: context.handle,
                    onStdout: FFmpeg.progressHandler(duration: duration, reporter: context.progress))
                if result.cancelled { throw ProcessError.cancelled }
                guard result.exitCode == 0 else {
                    throw ProcessError.failed(code: result.exitCode, message: result.stderr)
                }

                let frames = VideoSupport.sequence(in: scratch, prefix: "f_")
                let fpsForTimecode = info?.frameRate ?? 30
                let useTimecode = context.choice("naming", "index") == "timecode"

                for (i, frame) in frames.enumerated() {
                    let name: String
                    if useTimecode {
                        let seconds = fpsForTimecode > 0 ? Double(i) / fpsForTimecode : Double(i)
                        name = "\(base)_\(timecode(seconds)).\(format)"
                    } else {
                        name = "\(base)_\(String(format: "%05d", i + 1)).\(format)"
                    }
                    let target = destination.appendingPathComponent(name)
                    if let committed = try FileIO.commit(
                        frame, to: target, policy: context.settings.conflictPolicy) {
                        outputs.append(committed)
                    }
                }
            }
            return VideoSupport.summarise(outputs, limit: 40)
        }
    ) }

    /// `00h01m23s456` style suffix, safe on every filesystem.
    private static func timecode(_ seconds: Double) -> String {
        let total = max(seconds, 0)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02dh%02dm%02ds%03d", h, m, s, ms)
    }
}

// MARK: - 3. Video to GIF

enum VideoToGifTool {
    static var tool: Tool { Tool(
        id: "video.gif",
        name: L("video.gif.name"),
        summary: L("video.gif.summary"),
        symbol: "photo.stack",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts"],
                requiresFFmpeg: true,
        actionTitle: L("image.gif.action"),
        parameters: [
            .number("start", L("video.frames.param.start.label"), default: 0, min: 0, max: 100_000, step: 0.1),
            .number("duration", L("video.gif.param.duration.label"), default: 5, min: 0.1, max: 600, step: 0.5,
                    hint: L("video.gif.param.duration.hint")),
            .slider("fps", L("ui.frame_rate"), default: 15, min: 5, max: 50, step: 1,
                    hint: L("video.gif.param.fps.hint")),
            .number("width", L("image.resize.param.width.label"), default: 480, min: 40, max: 2000, step: 20,
                    hint: L("video.gif.param.width.hint")),
            .picker("dither", L("video.gif.param.dither.label"), default: "sierra2_4a", options: [
                .init("none", L("enum.transition.none")), .init("bayer", "Bayer"), .init("sierra2_4a", "Sierra 2-4A"),
                .init("floyd_steinberg", "Floyd-Steinberg"),
            ]),
            .slider("colors", L("ui.palette_colours"), default: 256, min: 16, max: 256, step: 8,
                    hint: L("video.gif.param.colors.hint")),
            .picker("loop", L("ui.looping"), default: "forever", options: [
                .init("forever", L("video.gif.param.loop.label")), .init("once", L("video.gif.param.loop.label.2")), .init("3", L("video.gif.param.loop.label.3")),
            ]),
            .toggle("reverse", L("ui.reverse"), default: false),
            .toggle("highQuality", L("video.gif.param.highQuality.label"), default: true,
                    hint: L("video.gif.param.highQuality.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let output = context.output(index: index, ext: "gif", suffix: "")
                let start = context.double("start", 0)
                let clipDuration = context.double("duration", 5)
                let fps = context.double("fps", 15)
                let width = context.int("width", 480)
                let dither = context.choice("dither", "sierra2_4a")
                let colors = context.int("colors", 256)
                let reverse = context.bool("reverse", false)

                var chain = "fps=\(VideoSupport.fmt(fps)),scale=\(width):-2:flags=lanczos"
                if reverse { chain += ",reverse" }

                let scratch = try context.makeScratch()
                defer { FileIO.removeQuietly(scratch) }
                let paletteURL = scratch.appendingPathComponent("palette.png")
                let temp = scratch.appendingPathComponent("out.gif")

                let seek = ["-ss", VideoSupport.fmt(start), "-t", VideoSupport.fmt(clipDuration), "-i", input.path]

                if context.bool("highQuality", true) {
                    // Pass 1: derive an optimal palette from the actual clip.
                    let paletteArgs = FFmpeg.baseFlags + seek + [
                        "-vf", "\(chain),palettegen=max_colors=\(colors):stats_mode=diff",
                        "-y", paletteURL.path,
                    ]
                    let pass1 = try await ProcessRunner.run(
                        "ffmpeg", paletteArgs, handle: context.handle)
                    if pass1.cancelled { throw ProcessError.cancelled }
                    guard pass1.exitCode == 0 else {
                        throw ProcessError.failed(code: pass1.exitCode, message: pass1.stderr)
                    }

                    // Pass 2: apply the palette.
                    let useArgs = FFmpeg.baseFlags + [
                        "-progress", "pipe:1",
                        "-ss", VideoSupport.fmt(start), "-t", VideoSupport.fmt(clipDuration),
                        "-i", input.path, "-i", paletteURL.path,
                        "-lavfi", "\(chain)[x];[x][1:v]paletteuse=dither=\(dither)",
                        "-loop", loopValue(context),
                        "-y", temp.path,
                    ]
                    let pass2 = try await ProcessRunner.run(
                        "ffmpeg", useArgs, handle: context.handle,
                        onStdout: FFmpeg.progressHandler(duration: clipDuration, reporter: context.progress))
                    if pass2.cancelled { throw ProcessError.cancelled }
                    guard pass2.exitCode == 0 else {
                        throw ProcessError.failed(code: pass2.exitCode, message: pass2.stderr)
                    }
                } else {
                    let args = FFmpeg.baseFlags + [
                        "-progress", "pipe:1",
                    ] + seek + [
                        "-vf", "\(chain),split[s0][s1];[s0]palettegen=max_colors=\(colors)[p];[s1][p]paletteuse=dither=\(dither)",
                        "-loop", loopValue(context),
                        "-y", temp.path,
                    ]
                    let result = try await ProcessRunner.run(
                        "ffmpeg", args, handle: context.handle,
                        onStdout: FFmpeg.progressHandler(duration: clipDuration, reporter: context.progress))
                    if result.cancelled { throw ProcessError.cancelled }
                    guard result.exitCode == 0 else {
                        throw ProcessError.failed(code: result.exitCode, message: result.stderr)
                    }
                }

                if let committed = try FileIO.commit(
                    temp, to: output, policy: context.settings.conflictPolicy) {
                    outputs.append(committed)
                }
            }
            return outputs
        }
    ) }

    private static func loopValue(_ context: ToolContext) -> String {
        switch context.choice("loop", "forever") {
        case "once": return "-1"
        case "3": return "2"
        default: return "0"
        }
    }
}

// MARK: - 4. Image sequence to video

enum ImagesToVideoTool {
    static var tool: Tool { Tool(
        id: "video.fromimages",
        name: L("video.fromimages.name"),
        summary: L("video.fromimages.summary"),
        symbol: "photo.on.rectangle.angled",
        category: .video,
        accepts: ["png", "jpg", "jpeg", "tiff", "bmp", "heic", "webp"],
                requiresFFmpeg: true,
        actionTitle: L("video.fromimages.action"),
        parameters: [
            .slider("fps", L("ui.frame_rate"), default: 30, min: 1, max: 120, step: 1),
            .picker("codec", L("video.fromimages.param.codec.label"), default: "h264", options: [
                .init("h264", "H.264"), .init("hevc", "H.265"), .init("prores", "ProRes"),
            ]),
            .slider("crf", L("video.fromimages.param.crf.label"), default: 18, min: 10, max: 34, step: 1),
            .number("width", L("video.fromimages.param.width.label"), default: 0, min: 0, max: 7680, step: 2,
                    hint: L("video.fromimages.param.width.hint")),
            .picker("fit", L("video.fromimages.param.fit.label"), default: "pad", options: [
                .init("pad", L("video.fromimages.param.fit.label.2")), .init("crop", L("enum.fitmode.contain.2")),
            ]),
            .toggle("loop", L("video.fromimages.param.loop.label"), default: false),
            .number("holdSeconds", L("video.fromimages.param.holdSeconds.label"), default: 0, min: 0, max: 60, step: 0.1,
                    hint: L("video.fromimages.param.holdSeconds.hint")),
        ],
        minimumInputs: 2,
        run: { context in
            let scratch = try context.makeScratch()
            defer { FileIO.removeQuietly(scratch) }

            // ffmpeg's image2 demuxer needs uniform names, so relink the inputs.
            let ext = context.inputs[0].pathExtension.lowercased()
            for (i, url) in context.inputs.enumerated() {
                let target = scratch.appendingPathComponent(
                    String(format: "frame_%05d.%@", i + 1, ext))
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
            }

            let codec = VideoCodec(rawValue: context.choice("codec", "h264")) ?? .h264
            let output = context.output(ext: codec.preferredExtension, suffix: L("video.fromimages.param.holdSeconds.label.2"))
            var fps = context.double("fps", 30)
            let hold = context.double("holdSeconds", 0)
            if hold > 0 { fps = 1 / hold }

            let width = context.int("width", 0)
            var filters: [String] = []
            if width > 0 {
                if context.choice("fit", "pad") == "crop" {
                    filters.append("scale=\(width):-2:force_original_aspect_ratio=increase")
                } else {
                    filters.append("scale=\(width):-2:force_original_aspect_ratio=decrease")
                }
            }
            if context.bool("loop") {
                // Reverse then forward, played once, gives a seamless loop.
                filters.append("split[a][b];[b]reverse[r];[a][r]concat=n=2:v=1:a=0")
            }

            var args = [
                "-framerate", VideoSupport.fmt(fps),
                "-i", scratch.appendingPathComponent("frame_%05d.\(ext)").path,
            ]
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            args += FFmpeg.videoArgs(
                codec: codec,
                quality: context.double("crf", 18),
                hardware: context.settings.useHardwareAcceleration && codec != .prores,
                preset: "medium")
            args += ["-pix_fmt", "yuv420p"]

            let total = Double(context.inputs.count) / max(fps, 0.001)
            return [try await VideoSupport.encode(
                context, input: context.inputs[0], output: output,
                arguments: args, duration: total)]
        }
    ) }
}

// MARK: - 5. Slideshow with transitions

enum SlideshowTool {
    static var tool: Tool { Tool(
        id: "video.slideshow",
        name: L("video.slideshow.name"),
        summary: L("video.slideshow.summary"),
        symbol: "rectangle.stack",
        category: .video,
        // Images make up the slideshow; an audio file may be added for music.
        accepts: ["png", "jpg", "jpeg", "tiff", "bmp", "heic", "webp",
                  "mp3", "m4a", "aac", "wav", "flac", "opus", "aiff"],
                requiresFFmpeg: true,
        actionTitle: L("video.slideshow.action"),
        parameters: [
            .number("perImage", L("video.slideshow.param.perImage.label"), default: 3, min: 0.5, max: 60, step: 0.5),
            .picker("transition", L("ui.transition"), default: "fade", options: [
                .init("none", L("enum.transition.none")), .init("fade", L("enum.transition.none.2")), .init("wipeleft", L("enum.transition.none.5")),
                .init("wiperight", L("enum.transition.none.6")), .init("slideleft", L("enum.transition.none.3")),
                .init("circleopen", L("enum.transition.none.7")), .init("dissolve", L("video.slideshow.param.transition.label")),
            ]),
            .number("transitionDuration", L("video.slideshow.param.transitionDuration.label"), default: 0.6, min: 0.1, max: 5, step: 0.1,
                    visibleWhen: .notEquals("transition", "none")),
            .picker("resolution", L("video.screenshot.param.scale.label"), default: "1080p", options: [
                .init("1080p", "1920×1080"), .init("720p", "1280×720"),
                .init("4k", "3840×2160"), .init("square", L("video.slideshow.param.resolution.label")),
                .init("vertical", L("video.slideshow.param.resolution.label.2")),
            ]),
            .picker("fit", L("ui.image_fitting"), default: "contain", options: [
                .init("contain", L("video.slideshow.param.fit.label")), .init("cover", L("enum.fitmode.contain.2")),
            ]),
            .text("background", L("ui.background"), default: "black", hint: L("video.slideshow.param.background.hint")),
            .picker("fps", L("ui.frame_rate"), default: "30", options: [
                .init("24", "24"), .init("30", "30"), .init("60", "60"),
            ]),
            .toggle("kenBurns", L("video.slideshow.param.kenBurns.label"), default: false,
                    hint: L("video.slideshow.param.kenBurns.hint")),
            .slider("crf", L("video.fromimages.param.crf.label"), default: 20, min: 12, max: 34, step: 1),
        ],
        hasCustomEditor: true,
        minimumInputs: 2,
        run: { context in
            let perImage = context.double("perImage", 3)
            let transition = context.choice("transition", "fade")
            let transitionDuration = transition == "none" ? 0 : context.double("transitionDuration", 0.6)
            let fps = Double(context.choice("fps", "30")) ?? 30
            let (width, height) = slideshowDimensions(context.choice("resolution", "1080p"))
            let background = context.string("background", "black")
            let fit = context.choice("fit", "contain")
            let images = context.inputs.filter { !$0.pathExtension.isAudioExtension }
            guard images.count >= 2 else {
                throw ProcessError.failed(code: 0, message: L("video.slideshow.param.crf.label"))
            }

            let output = context.output(ext: "mp4", suffix: L("video.slideshow.param.crf.label.2"))
            let scratch = try context.makeScratch()
            defer { FileIO.removeQuietly(scratch) }

            // Normalise every image to the same size and pixel format first;
            // xfade requires identical geometry across inputs.
            var normalised: [URL] = []
            for (i, image) in images.enumerated() {
                try context.checkCancelled()
                let target = scratch.appendingPathComponent(String(format: "n_%04d.png", i))
                var filters = "scale=\(width):\(height):force_original_aspect_ratio=\(fit == "cover" ? "increase" : "decrease")"
                if fit == "cover" {
                    filters += ",crop=\(width):\(height)"
                } else {
                    filters += ",pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=\(background)"
                }
                filters += ",setsar=1,format=yuv420p"
                if context.bool("kenBurns", false) {
                    // zoompan needs a generous source so the zoom stays sharp.
                    filters += ",scale=\(width * 2):\(height * 2),zoompan=z='min(zoom+0.0008,1.15)':d=\(Int(perImage * fps)):s=\(width)x\(height):fps=\(VideoSupport.fmt(fps))"
                }
                let args = FFmpeg.baseFlags + [
                    "-i", image.path, "-vf", filters, "-frames:v", "1", "-y", target.path,
                ]
                let result = try await ProcessRunner.run("ffmpeg", args, handle: context.handle)
                guard result.exitCode == 0 else {
                    throw ProcessError.failed(code: result.exitCode,
                                              message: L("video.slideshow.param.crf.label.3", image.lastPathComponent, result.stderr))
                }
                normalised.append(target)
                context.progress.report(Double(i + 1) / Double(images.count) * 0.3)
            }

            // Build the xfade chain. Every still is its own ffmpeg input, so
            // the preamble is assembled here rather than by the helper.
            var inputArguments: [String] = []
            for url in normalised {
                // A still decodes to a single frame; loop it so the xfade
                // offsets below actually have footage to blend.
                inputArguments += ["-loop", "1", "-t", VideoSupport.fmt(perImage), "-i", url.path]
            }
            let audioInput = context.inputs.first(where: { $0.pathExtension.isAudioExtension })
            if let audioInput { inputArguments += ["-i", audioInput.path] }
            var args: [String] = []

            var filters: [String] = []
            var lastLabel = "0:v"
            var offset = perImage - transitionDuration

            for i in 1..<normalised.count {
                let outLabel = i == normalised.count - 1 ? "vout" : "v\(i)"
                if transition == "none" {
                    filters.append("[\(lastLabel)][\(i):v]concat=n=2:v=1:a=0[\(outLabel)]")
                } else {
                    filters.append(
                        "[\(lastLabel)][\(i):v]xfade=transition=\(transition):duration=\(VideoSupport.fmt(transitionDuration)):offset=\(VideoSupport.fmt(offset))[\(outLabel)]")
                    offset += perImage - transitionDuration
                }
                lastLabel = outLabel
            }
            if normalised.count == 1 { filters.append("[0:v]null[vout]") }

            args += ["-filter_complex", filters.joined(separator: ";")]
            args += ["-map", "[vout]"]
            if context.inputs.contains(where: { $0.pathExtension.isAudioExtension }) {
                args += ["-map", "\(normalised.count):a", "-shortest"]
                args += ["-c:a", "aac", "-b:a", "192k"]
            }
            args += FFmpeg.videoArgs(codec: .h264, quality: context.double("crf", 20),
                                     hardware: context.settings.useHardwareAcceleration,
                                     preset: "medium")
            args += ["-r", VideoSupport.fmt(fps), "-pix_fmt", "yuv420p", "-movflags", "+faststart"]

            let total = Double(normalised.count) * perImage
            let produced = try await VideoSupport.encode(
                context, input: normalised[0], output: output,
                arguments: args, duration: total, inputArguments: inputArguments)
            context.progress.report(1)
            return [produced]
        }
    ) }

    private static func slideshowDimensions(_ preset: String) -> (Int, Int) {
        switch preset {
        case "720p": return (1280, 720)
        case "4k": return (3840, 2160)
        case "square": return (1080, 1080)
        case "vertical": return (1080, 1920)
        default: return (1920, 1080)
        }
    }
}
