import Foundation

// MARK: - 1. Format conversion

enum VideoConvertTool {
    static var tool: Tool { Tool(
        id: "video.convert",
        name: L("video.convert.name"),
        summary: L("video.convert.summary"),
        symbol: "arrow.triangle.2.circlepath",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "ts", "3gp", "ogv", "mts", "m2ts"],
                requiresFFmpeg: true,
        actionTitle: L("ui.start"),
        parameters: [
            .picker("codec", L("video.fromimages.param.codec.label"), default: "h264", options: VideoOptions.codecs),
            .picker("container", L("video.convert.param.container.label"), default: "mp4", options: [
                .init("mp4", "MP4"), .init("mov", "MOV"), .init("mkv", "MKV"),
                .init("webm", "WebM"), .init("avi", "AVI"),
            ]),
            .picker("audioCodec", L("video.convert.param.audioCodec.label"), default: "aac", options: VideoOptions.audio),
            .slider("audioBitrate", L("video.convert.param.audioBitrate.label"), default: 192, min: 64, max: 512, step: 32,
                    visibleWhen: .oneOf("audioCodec", ["aac", "mp3", "opus"])),
        ] + VideoOptions.qualityParameters() + [
            .picker("scale", L("ui.dimensions"), default: "original", options: VideoOptions.scale),
            .number("customWidth", L("video.screenshot.param.customWidth.label"), default: 1280, min: 16, max: 7680,
                    visibleWhen: .equals("scale", "custom")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let codec = VideoCodec(rawValue: context.choice("codec", "h264")) ?? .h264
                let audioCodec = AudioCodec(rawValue: context.choice("audioCodec", "aac")) ?? .aac

                var ext = context.choice("container", "mp4")
                // WebM cannot carry H.264; align the container with the codec.
                if codec == .vp9 || codec == .av1 {
                    if !["webm", "mkv"].contains(ext) { ext = "webm" }
                } else if ext == "webm" {
                    ext = "mp4"
                }

                let output = context.output(index: index, ext: ext, suffix: "")
                var args: [String] = []
                args += VideoSupport.qualityArguments(context, codec: codec)
                args += VideoSupport.geometryArguments(context)
                args += FFmpeg.audioArgs(
                    codec: audioCodec,
                    bitrateKbps: context.int("audioBitrate", 192)
                )
                if context.settings.keepMetadata {
                    args += ["-map_metadata", "0"]
                }
                if ext == "mp4" || ext == "mov" {
                    args += ["-movflags", "+faststart"]
                }

                context.progress.note(L("video.convert.param.customWidth.label", input.lastPathComponent))
                let produced = try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration)
                outputs.append(produced)
            }
            return outputs
        }
    ) }
}

// MARK: - 2. Smart compression

enum VideoCompressTool {
    static var tool: Tool { Tool(
        id: "video.compress",
        name: L("video.compress.name"),
        summary: L("video.compress.summary"),
        symbol: "arrow.down.right.and.arrow.up.left",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "ts"],
                requiresFFmpeg: true,
        actionTitle: L("archive.create.action"),
        parameters: [
            .picker("mode", L("image.compress.param.mode.label"), default: "quality", options: [
                .init("quality", L("image.compress.param.mode.label.2"), detail: L("video.compress.param.mode.label")),
                .init("size", L("image.compress.param.mode.label.3"), detail: L("video.compress.param.mode.label.2")),
                .init("bitrate", L("video.compress.param.mode.label.3"), detail: L("video.compress.param.mode.label.4")),
            ]),
            .slider("crf", L("video.fromimages.param.crf.label"), default: 26, min: 14, max: 40, step: 1,
                    hint: L("video.compress.param.crf.hint"),
                    visibleWhen: .equals("mode", "quality")),
            .number("targetSize", L("video.compress.param.targetSize.label"), default: 20, min: 1, max: 100_000, step: 1,
                    visibleWhen: .equals("mode", "size")),
            .number("videoBitrate", L("video.compress.param.videoBitrate.label"), default: 2500, min: 100, max: 200_000, step: 100,
                    visibleWhen: .equals("mode", "bitrate")),
            .picker("scale", L("ui.dimensions"), default: "original", options: VideoOptions.scale),
            .number("customWidth", L("video.screenshot.param.customWidth.label"), default: 1280, min: 16, max: 7680,
                    visibleWhen: .equals("scale", "custom")),
            .picker("codec", L("video.fromimages.param.codec.label"), default: "h264", options: [
                .init("h264", "H.264", detail: L("enum.codec.h264")),
                .init("hevc", "H.265", detail: L("enum.codec.h264.2")),
                .init("av1", "AV1", detail: L("video.compress.param.codec.label")),
            ]),
            .picker("audioCodec", L("video.convert.param.audioCodec.label"), default: "aac", options: VideoOptions.audio),
            .slider("audioBitrate", L("video.convert.param.audioBitrate.label"), default: 128, min: 32, max: 320, step: 32),
            .toggle("hardware", L("ui.use_hardware_acceleration_videotoolbox"), default: false,
                    hint: L("video.compress.param.hardware.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let info = await MediaProbe.info(for: input)
                let duration = info?.duration ?? 0
                let codec = VideoCodec(rawValue: context.choice("codec", "h264")) ?? .h264
                let audioCodec = AudioCodec(rawValue: context.choice("audioCodec", "aac")) ?? .aac
                let mode = context.choice("mode", "quality")
                let output = context.output(index: index, ext: codec.preferredExtension, suffix: L("doc.pdfcompress.param.grayscale.label.2"))

                var args: [String] = []
                var passLog: URL?

                switch mode {
                case "size":
                    guard duration > 0 else {
                        throw ProcessError.failed(code: 0, message: L("video.compress.param.hardware.label"))
                    }
                    let targetMB = max(context.double("targetSize", 20), 0.5)
                    let audioKbps = Double(context.int("audioBitrate", 128))
                    // Reserve 2% for container overhead.
                    let totalKbps = (targetMB * 8 * 1024) / duration
                    let videoKbps = max(Int((totalKbps - audioKbps) * 0.98), 80)
                    passLog = try context.makeScratch().appendingPathComponent("pass")
                    args += FFmpeg.videoArgs(
                        codec: codec, quality: 23,
                        hardware: context.bool("hardware", true),
                        targetBitrateKbps: videoKbps)
                    args += VideoSupport.geometryArguments(context)
                    args += FFmpeg.audioArgs(codec: audioCodec, bitrateKbps: context.int("audioBitrate", 128))
                    // Two-pass is only meaningful for software encoders, and
                    // the analysis pass must not appear in the final command.
                    if !context.bool("hardware", true) && codec == .h264, let passLog {
                        let analysisArgs = ["-i", input.path] + args + [
                            "-pass", "1", "-passlogfile", passLog.path,
                            "-an", "-f", "null", "/dev/null",
                        ]
                        _ = try? await ProcessRunner.run(
                            "ffmpeg", FFmpeg.baseFlags + analysisArgs, handle: context.handle)
                        args += ["-pass", "2", "-passlogfile", passLog.path]
                    }

                case "bitrate":
                    args += FFmpeg.videoArgs(
                        codec: codec, quality: 23,
                        hardware: context.bool("hardware", true),
                        targetBitrateKbps: context.int("videoBitrate", 2500))
                    args += VideoSupport.geometryArguments(context)
                    args += FFmpeg.audioArgs(codec: audioCodec, bitrateKbps: context.int("audioBitrate", 128))

                default:
                    let crf = context.double("crf", 26)
                    args += FFmpeg.videoArgs(
                        codec: codec, quality: crf,
                        hardware: context.bool("hardware", true),
                        preset: "medium")
                    args += VideoSupport.geometryArguments(context)
                    args += FFmpeg.audioArgs(codec: audioCodec, bitrateKbps: context.int("audioBitrate", 128))
                }

                if context.settings.keepMetadata { args += ["-map_metadata", "0"] }
                if output.pathExtension == "mp4" { args += ["-movflags", "+faststart"] }

                context.progress.note(L("video.compress.param.hardware.label.2", input.lastPathComponent))
                let produced = try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration)
                if let passLog { FileIO.removeQuietly(passLog) }
                outputs.append(produced)
            }
            return outputs
        }
    ) }
}

// MARK: - 3. Audio extract / remove

enum AudioExtractTool {
    static var tool: Tool { Tool(
        id: "video.audio.extract",
        name: L("video.compress.name.2"),
        summary: L("video.compress.summary.2"),
        symbol: "waveform.badge.minus",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "flv", "wmv", "m4v", "ts", "mpg", "mpeg"],
                requiresFFmpeg: true,
        actionTitle: L("video.audio.extract.action"),
        actionVariants: ["action=remove": L("enum.audio.aac.5")],
        parameters: [
            .picker("action", L("doc.pdfsecurity.param.action.label"), default: "extract", options: [
                .init("extract", L("video.compress.action")), .init("remove", L("video.compress.param.action.label")),
            ]),
            .picker("format", L("video.compress.param.format.label"), default: "m4a", options: [
                .init("m4a", "M4A (AAC)"), .init("mp3", "MP3"), .init("wav", "WAV"),
                .init("flac", L("enum.audio.aac")), .init("opus", "Opus"),
            ], visibleWhen: .equals("action", "extract")),
            .slider("bitrate", L("video.convert.param.audioBitrate.label"), default: 192, min: 64, max: 320, step: 32,
                    visibleWhen: .oneOf("action", ["extract"])),
            .toggle("keepVideo", L("video.compress.param.keepVideo.label"), default: false,
                    hint: L("video.compress.param.keepVideo.hint"),
                    visibleWhen: .equals("action", "extract")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let action = context.choice("action", "extract")

                if action == "remove" {
                    let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.compress.param.keepVideo.label.2"))
                    let args = ["-c", "copy", "-an"]
                    outputs.append(try await VideoSupport.encode(
                        context, input: input, output: output, arguments: args, duration: duration))
                    continue
                }

                let format = context.choice("format", "m4a")
                let audioCodec: AudioCodec = switch format {
                case "mp3": .mp3
                case "wav": .pcm
                case "flac": .flac
                case "opus": .opus
                default: .aac
                }
                let output = context.output(index: index, ext: format, suffix: "")
                var args = ["-vn"]
                args += FFmpeg.audioArgs(codec: audioCodec, bitrateKbps: context.int("bitrate", 192))
                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output, arguments: args, duration: duration))

                if context.bool("keepVideo") {
                    let silent = context.output(index: index, ext: input.pathExtension, suffix: L("video.compress.param.keepVideo.label.3"))
                    let silentArgs = ["-c:v", "copy", "-an"]
                    outputs.append(try await VideoSupport.encode(
                        context, input: input, output: silent, arguments: silentArgs, duration: duration))
                }
            }
            return outputs
        }
    ) }
}

// MARK: - 4. Merge audio into video

enum AudioMergeTool {
    static var tool: Tool { Tool(
        id: "video.audio.merge",
        name: L("video.compress.name.3"),
        summary: L("video.compress.summary.3"),
        symbol: "waveform.badge.plus",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts", "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus"],
                requiresFFmpeg: true,
        actionTitle: L("doc.pdfmerge.action"),
        parameters: [
            .picker("mode", L("video.compress.param.mode.label.5"), default: "replace", options: [
                .init("replace", L("video.compress.param.mode.label.6"), detail: L("video.compress.param.mode.label.7")),
                .init("mix", L("video.compress.param.mode.label.8"), detail: L("video.compress.param.mode.label.9")),
            ]),
            .slider("volume", L("video.compress.param.volume.label"), default: 100, min: 0, max: 300, step: 5),
            .slider("originalVolume", L("video.compress.param.originalVolume.label"), default: 100, min: 0, max: 300, step: 5,
                    visibleWhen: .equals("mode", "mix")),
            .number("offset", L("video.compress.param.offset.label"), default: 0, min: -600, max: 600, step: 0.1,
                    hint: L("video.compress.param.offset.hint")),
            .number("fadeIn", L("video.compress.param.fadeIn.label"), default: 0, min: 0, max: 60, step: 0.5),
            .number("fadeOut", L("video.compress.param.fadeOut.label"), default: 0, min: 0, max: 60, step: 0.5),
            .picker("audioCodec", L("video.compress.param.audioCodec.label"), default: "aac", options: [
                .init("aac", "AAC"), .init("mp3", "MP3"), .init("flac", "FLAC"), .init("copy", L("ui.copy")),
            ]),
            .toggle("shortest", L("video.compress.param.shortest.label"), default: true),
        ],
        minimumInputs: 2,
        run: { context in
            // Convention: the first video file and the first audio file are paired.
            let videos = context.inputs.filter { !$0.pathExtension.isAudioExtension }
            let audios = context.inputs.filter { $0.pathExtension.isAudioExtension }
            guard let video = videos.first, let audio = audios.first else {
                throw ProcessError.failed(code: 0, message: L("video.compress.param.shortest.label.2"))
            }

            let duration = await MediaProbe.duration(video)
            let output = context.output(ext: video.pathExtension, suffix: L("video.compress.param.shortest.label.3"))
            let mode = context.choice("mode", "replace")
            let newVolume = context.double("volume", 100) / 100
            let oldVolume = context.double("originalVolume", 100) / 100
            let offset = context.double("offset", 0)
            let fadeIn = context.double("fadeIn", 0)
            let fadeOut = context.double("fadeOut", 0)

            var filters: [String] = []
            // Collect only the filters the user actually asked for; an empty
            // chain must still pass audio through, so fall back to anull.
            var steps: [String] = []
            if newVolume != 1 { steps.append("volume=\(VideoSupport.fmt(newVolume))") }
            if offset != 0 {
                let ms = Int(offset * 1000)
                steps.append("adelay=\(max(ms, 0))|\(max(ms, 0))")
            }
            if fadeIn > 0 { steps.append("afade=t=in:st=0:d=\(VideoSupport.fmt(fadeIn))") }
            if fadeOut > 0, duration > fadeOut {
                steps.append("afade=t=out:st=\(VideoSupport.fmt(duration - fadeOut)):d=\(VideoSupport.fmt(fadeOut))")
            }
            if steps.isEmpty { steps.append("anull") }
            filters.append("[1:a]\(steps.joined(separator: ","))[a1]")

            let inputArguments = ["-i", video.path, "-i", audio.path]
            var args: [String] = []
            if mode == "mix" {
                filters.append("[0:a]volume=\(VideoSupport.fmt(oldVolume))[a0]")
                filters.append("[a0][a1]amix=inputs=2:duration=first:dropout_transition=0[aout]")
                args += ["-filter_complex", filters.joined(separator: ";")]
                args += ["-map", "0:v", "-map", "[aout]"]
            } else {
                args += ["-filter_complex", filters.joined(separator: ";")]
                args += ["-map", "0:v", "-map", "[a1]"]
            }
            args += ["-c:v", "copy"]
            let audioCodec = AudioCodec(rawValue: context.choice("audioCodec", "aac")) ?? .aac
            args += FFmpeg.audioArgs(codec: audioCodec, bitrateKbps: 192)
            if context.bool("shortest", true) { args += ["-shortest"] }

            return [try await VideoSupport.encode(
                context, input: video, output: output, arguments: args,
                duration: duration, inputArguments: inputArguments)]
        }
    ) }
}

// MARK: - 5. Concatenate

enum VideoConcatTool {
    static var tool: Tool { Tool(
        id: "video.concat",
        name: L("video.concat.name"),
        summary: L("video.concat.summary"),
        symbol: "rectangle.stack.badge.plus",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts"],
                requiresFFmpeg: true,
        actionTitle: L("image.stitch.action"),
        parameters: [
            .picker("mode", L("image.stitch.param.layout.label"), default: "reencode", options: [
                .init("reencode", L("video.concat.param.mode.label"), detail: L("video.concat.param.mode.label.2")),
                .init("copy", L("video.concat.param.mode.label.3"), detail: L("video.concat.param.mode.label.4")),
            ]),
            .picker("codec", L("video.concat.param.codec.label"), default: "h264", options: [
                .init("h264", "H.264"), .init("hevc", "H.265"),
            ], visibleWhen: .equals("mode", "reencode")),
            .slider("crf", L("video.fromimages.param.crf.label"), default: 20, min: 14, max: 34, step: 1,
                    visibleWhen: .equals("mode", "reencode")),
            .toggle("normalize", L("video.concat.param.normalize.label"), default: true,
                    hint: L("video.concat.param.normalize.hint"),
                    visibleWhen: .equals("mode", "reencode")),
        ],
        minimumInputs: 2,
        run: { context in
            guard context.inputs.count >= 2 else {
                throw ProcessError.failed(code: 0, message: L("video.concat.param.normalize.label.2"))
            }
            let scratch = try context.makeScratch()
            defer { FileIO.removeQuietly(scratch) }

            let listURL = scratch.appendingPathComponent("list.txt")
            let listing = context.inputs
                .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: "\n")
            try listing.write(to: listURL, atomically: true, encoding: .utf8)

            let output = context.output(ext: context.inputs[0].pathExtension, suffix: L("video.concat.param.normalize.label.3"))
            let totalDuration = await withTaskGroup(of: Double.self) { group in
                for input in context.inputs {
                    group.addTask { await MediaProbe.duration(input) }
                }
                var sum: Double = 0
                for await value in group { sum += value }
                return sum
            }

            // The concat demuxer consumes the whole list as a single input.
            let inputArguments = ["-f", "concat", "-safe", "0", "-i", listURL.path]

            if context.choice("mode", "reencode") == "copy" {
                return [try await VideoSupport.encode(
                    context, input: context.inputs[0], output: output,
                    arguments: ["-c", "copy"], duration: totalDuration,
                    inputArguments: inputArguments)]
            }

            let codec = VideoCodec(rawValue: context.choice("codec", "h264")) ?? .h264
            let first = await MediaProbe.info(for: context.inputs[0])
            var filters: [String] = []
            var args: [String] = []

            if context.bool("normalize", true), let first, first.width > 0 {
                let w = first.width - (first.width % 2)
                let h = first.height - (first.height % 2)
                let fps = first.frameRate > 0 ? first.frameRate : 30
                filters.append("scale=\(w):\(h):force_original_aspect_ratio=decrease")
                filters.append("pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2")
                filters.append("fps=\(VideoSupport.fmt(fps))")
                filters.append("setsar=1")
            }
            if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
            args += FFmpeg.videoArgs(
                codec: codec,
                quality: context.double("crf", 20),
                hardware: context.settings.useHardwareAcceleration,
                preset: "medium")
            args += ["-c:a", "aac", "-b:a", "192k"]

            return [try await VideoSupport.encode(
                context, input: context.inputs[0], output: output,
                arguments: args, duration: totalDuration,
                inputArguments: inputArguments)]
        }
    ) }
}

// MARK: - 6. Cover art

enum VideoCoverTool {
    static var tool: Tool { Tool(
        id: "video.cover",
        name: L("video.cover.name"),
        summary: L("video.cover.summary"),
        symbol: "photo.badge.arrow.down",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "m4v", "png", "jpg", "jpeg", "heic", "tiff", "bmp", "webp"],
                requiresFFmpeg: true,
        actionTitle: L("video.cover.action"),
        actionVariants: ["action=extract": L("ui.extract_cover"), "action=frame": L("ui.generate_cover")],
        parameters: [
            .picker("action", L("doc.pdfsecurity.param.action.label"), default: "set", options: [
                .init("set", L("video.cover.action"), detail: L("video.cover.param.action.label")),
                .init("extract", L("ui.extract_cover"), detail: L("video.cover.param.action.label.2")),
                .init("frame", L("video.cover.param.action.label.3"), detail: L("video.cover.param.action.label.4")),
            ]),
            .number("timestamp", L("video.screenshot.param.timestamp.label"), default: 1, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .oneOf("action", ["frame"])),
            .picker("format", L("video.cover.param.format.label"), default: "jpg", options: [
                .init("jpg", "JPG"), .init("png", "PNG"),
            ], visibleWhen: .oneOf("action", ["extract", "frame"])),
        ],
        minimumInputs: 1,
        run: { context in
            let action = context.choice("action", "set")

            if action == "set" {
                let videos = context.inputs.filter { !$0.pathExtension.isImageExtension }
                let images = context.inputs.filter { $0.pathExtension.isImageExtension }
                guard let video = videos.first, let image = images.first else {
                    throw ProcessError.failed(code: 0, message: L("video.cover.param.format.label.2"))
                }
                let output = context.output(ext: video.pathExtension, suffix: L("video.cover.param.format.label.3"))
                let args = [
                    "-map", "0", "-map", "1",
                    "-c", "copy",
                    "-disposition:v:1", "attached_pic",
                    "-metadata:s:v:1", "title=Cover",
                ]
                return [try await VideoSupport.encode(
                    context, input: video, output: output, arguments: args,
                    duration: await MediaProbe.duration(video),
                    inputArguments: ["-i", video.path, "-i", image.path])]
            }

            guard let video = context.inputs.first else {
                throw ProcessError.failed(code: 0, message: L("video.cover.param.format.label.4"))
            }
            let format = context.choice("format", "jpg")
            let output = context.output(ext: format, suffix: L("video.cover.param.format.label.3"))

            if action == "extract" {
                // Prefer an embedded attached picture; fall back to the first frame.
                let info = (try? await ProcessRunner.capture("ffprobe", [
                    "-v", "error", "-select_streams", "v",
                    "-show_entries", "stream=index,disposition=attached_pic",
                    "-of", "csv=p=0", video.path,
                ])) ?? ""
                let hasAttached = info.split(separator: "\n").contains { $0.contains("1") }
                var args: [String] = []
                if hasAttached {
                    args += ["-map", "0:v:1", "-frames:v", "1"]
                } else {
                    args += ["-map", "0:v:0", "-frames:v", "1"]
                }
                args += ["-q:v", "2"]
                return [try await VideoSupport.encode(
                    context, input: video, output: output, arguments: args, duration: 0)]
            }

            let timestamp = context.double("timestamp", 1)
            let args = [
                "-ss", VideoSupport.fmt(timestamp),
                "-frames:v", "1", "-q:v", "2",
            ]
            return [try await VideoSupport.encode(
                context, input: video, output: output, arguments: args, duration: 0)]
        }
    ) }
}

// MARK: - 7. Trim / split

enum VideoTrimTool {
    static var tool: Tool { Tool(
        id: "video.trim",
        name: L("video.trim.name"),
        summary: L("video.trim.summary"),
        symbol: "scissors",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "ts"],
                requiresFFmpeg: true,
        actionTitle: L("video.trim.action"),
        parameters: [
            .picker("mode", L("image.transform.param.crop.label"), default: "range", options: [
                .init("range", L("video.trim.param.mode.label")), .init("split", L("video.trim.param.mode.label.2")),
            ]),
            .number("start", L("video.frames.param.start.label"), default: 0, min: 0, max: 100_000, step: 0.1,
                    visibleWhen: .equals("mode", "range")),
            .number("end", L("video.screenshot.param.end.label"), default: 10, min: 0, max: 100_000, step: 0.1,
                    hint: L("video.screenshot.param.end.hint"),
                    visibleWhen: .equals("mode", "range")),
            .number("segments", L("video.trim.param.segments.label"), default: 2, min: 2, max: 50, step: 1,
                    visibleWhen: .equals("mode", "split")),
            .number("segmentLength", L("video.trim.param.segmentLength.label"), default: 0, min: 0, max: 100_000, step: 1,
                    hint: L("video.trim.param.segmentLength.hint"),
                    visibleWhen: .equals("mode", "split")),
            .toggle("reencode", L("video.trim.param.reencode.label"), default: true,
                    hint: L("video.trim.param.reencode.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let mode = context.choice("mode", "range")

                if mode == "split" {
                    let scratch = try context.makeScratch()
                    defer { FileIO.removeQuietly(scratch) }
                    var args: [String] = []
                    if context.bool("reencode", true) {
                        args += ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                                 "-c:a", "aac", "-b:a", "192k", "-force_key_frames", "expr:gte(t,n_forced*1)"]
                    } else {
                        args += ["-c", "copy"]
                    }
                    let length = context.double("segmentLength", 0)
                    if length > 0 {
                        args += ["-f", "segment", "-segment_time", VideoSupport.fmt(length), "-reset_timestamps", "1"]
                    } else {
                        let count = max(context.int("segments", 2), 2)
                        let per = duration > 0 ? duration / Double(count) : 0
                        guard per > 0 else {
                            throw ProcessError.failed(code: 0, message: L("video.trim.param.reencode.label.2"))
                        }
                        args += ["-f", "segment", "-segment_time", VideoSupport.fmt(per), "-reset_timestamps", "1"]
                    }
                    let pattern = scratch.appendingPathComponent("seg_%03d.\(input.pathExtension)").path
                    args += [pattern]

                    let full = ["-i", input.path] + args
                    let result = try await ProcessRunner.run(
                        "ffmpeg", FFmpeg.baseFlags + ["-progress", "pipe:1"] + full,
                        handle: context.handle,
                        onStdout: FFmpeg.progressHandler(duration: duration, reporter: context.progress))
                    guard result.ok || result.cancelled == false else {
                        throw ProcessError.failed(code: result.exitCode, message: result.stderr)
                    }
                    let produced = VideoSupport.sequence(in: scratch, prefix: "seg_")
                    for (i, file) in produced.enumerated() {
                        let target = context.output(
                            index: index, ext: input.pathExtension,
                            suffix: "_\(String(format: "%02d", i + 1))")
                        if let committed = try FileIO.commit(
                            file, to: target, policy: context.settings.conflictPolicy) {
                            outputs.append(committed)
                        }
                    }
                    continue
                }

                let start = context.double("start", 0)
                let end = context.double("end", 0)
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.trim.param.reencode.label.3"))
                let segmentDuration = end > start ? end - start : max(duration - start, 0)

                var args: [String] = []
                if context.bool("reencode", true) {
                    args += ["-ss", VideoSupport.fmt(start)]
                    if end > start { args += ["-to", VideoSupport.fmt(end)] }
                    args += ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                             "-c:a", "aac", "-b:a", "192k"]
                } else {
                    // Fast seek before input, then stream copy.
                    args += ["-ss", VideoSupport.fmt(start)]
                    if end > start { args += ["-to", VideoSupport.fmt(end)] }
                    args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
                }

                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: segmentDuration))
            }
            return outputs
        }
    ) }
}

// MARK: - 8. Transform (rotate / flip)

enum VideoTransformTool {
    static var tool: Tool { Tool(
        id: "video.transform",
        name: L("video.transform.name"),
        summary: L("video.transform.summary"),
        symbol: "rotate.right",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
                requiresFFmpeg: true,
        actionTitle: L("image.transform.action"),
        parameters: [
            .picker("transform", L("video.transform.param.transform.label"), default: "cw90", options: [
                .init("cw90", L("image.transform.param.rotate.label.2")), .init("ccw90", L("image.transform.param.rotate.label.3")),
                .init("180", L("video.transform.param.transform.label.2")), .init("hflip", L("image.transform.param.flipH.label")),
                .init("vflip", L("image.transform.param.flipV.label")),
            ]),
            .toggle("reencode", L("video.concat.param.mode.label"), default: true,
                    hint: L("video.transform.param.reencode.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("image.transform.param.format.label"))
                let transform = context.choice("transform", "cw90")

                var args: [String] = []
                if context.bool("reencode", true) {
                    let filter = switch transform {
                    case "cw90": "transpose=1"
                    case "ccw90": "transpose=2"
                    case "180": "transpose=2,transpose=2"
                    case "hflip": "hflip"
                    default: "vflip"
                    }
                    args += ["-vf", filter]
                    args += FFmpeg.videoArgs(codec: .h264, quality: 20,
                                             hardware: context.settings.useHardwareAcceleration,
                                             preset: "veryfast")
                    args += ["-c:a", "copy"]
                } else {
                    let rotation = switch transform {
                    case "cw90": "90"
                    case "ccw90": "270"
                    case "180": "180"
                    default: "0"
                    }
                    args += ["-c", "copy", "-metadata:s:v:0", "rotate=\(rotation)"]
                }

                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration))
            }
            return outputs
        }
    ) }
}

// MARK: - 9. Speed

enum VideoSpeedTool {
    static var tool: Tool { Tool(
        id: "video.speed",
        name: L("video.speed.name"),
        summary: L("video.speed.summary"),
        symbol: "speedometer",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
                requiresFFmpeg: true,
        actionTitle: L("video.speed.action"),
        parameters: [
            .slider("speed", L("video.speed.param.speed.label"), default: 2, min: 0.25, max: 8, step: 0.25,
                    hint: L("video.speed.param.speed.hint")),
            .toggle("keepPitch", L("video.speed.param.keepPitch.label"), default: true,
                    hint: L("video.speed.param.keepPitch.hint")),
            .toggle("dropAudio", L("video.compress.param.action.label"), default: false),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let sourceDuration = await MediaProbe.duration(input)
                let speed = context.double("speed", 2)
                guard speed > 0 else { throw ProcessError.failed(code: 0, message: L("video.speed.param.dropAudio.label")) }
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.speed.param.dropAudio.label.2"))

                var filters = ["setpts=PTS/\(VideoSupport.fmt(speed))"]
                if !context.bool("dropAudio") {
                    if context.bool("keepPitch", true) {
                        // atempo only accepts 0.5–2.0, so chain for larger factors.
                        var remaining = speed
                        var chain: [String] = []
                        while remaining > 2.0 {
                            chain.append("atempo=2.0"); remaining /= 2.0
                        }
                        while remaining < 0.5 {
                            chain.append("atempo=0.5"); remaining /= 0.5
                        }
                        chain.append("atempo=\(VideoSupport.fmt(remaining))")
                        filters.append(chain.joined(separator: ","))
                    } else {
                        filters.append("asetrate=48000*\(VideoSupport.fmt(speed))")
                    }
                }

                var args = ["-filter_complex", "[0:v]\(filters[0])[v]"]
                if filters.count > 1 {
                    args = ["-filter_complex", "[0:v]\(filters[0])[v];[0:a]\(filters[1])[a]"]
                    args += ["-map", "[v]", "-map", "[a]"]
                } else {
                    args += ["-map", "[v]"]
                    if !context.bool("dropAudio") { args += ["-map", "0:a?"] }
                }
                args += FFmpeg.videoArgs(codec: .h264, quality: 20,
                                         hardware: context.settings.useHardwareAcceleration,
                                         preset: "veryfast")
                if context.bool("dropAudio") {
                    args += ["-an"]
                } else if !context.bool("keepPitch", true) {
                    args += ["-c:a", "aac", "-b:a", "192k"]
                } else {
                    args += ["-c:a", "aac", "-b:a", "192k"]
                }

                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: sourceDuration / speed))
            }
            return outputs
        }
    ) }
}

// MARK: - 10. Watermark

enum VideoWatermarkTool {
    static var tool: Tool { Tool(
        id: "video.watermark",
        name: L("video.watermark.name"),
        summary: L("video.watermark.summary"),
        symbol: "signature",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
                requiresFFmpeg: true,
        actionTitle: L("image.watermark.action"),
        parameters: [
            .picker("kind", L("image.watermark.param.kind.label"), default: "text", options: [
                .init("text", L("image.watermark.param.kind.label.2")), .init("image", L("image.watermark.name")),
            ]),
            .text("text", L("image.watermark.param.text.label"), default: "FormatForge",
                  visibleWhen: .equals("kind", "text")),
            .slider("fontSize", L("video.watermark.param.fontSize.label"), default: 32, min: 8, max: 200, step: 1,
                    visibleWhen: .equals("kind", "text")),
            .text("color", L("video.watermark.param.color.label"), default: "white",
                  visibleWhen: .equals("kind", "text")),
            .number("imageScale", L("image.watermark.param.imageScale.label"), default: 20, min: 1, max: 100, step: 1,
                    visibleWhen: .equals("kind", "image")),
            .picker("position", L("ui.location"), default: "bottomRight", options: [
                .init("topLeft", L("enum.position.topleft")), .init("topRight", L("enum.position.topleft.2")),
                .init("bottomLeft", L("enum.position.topleft.3")), .init("bottomRight", L("enum.position.topleft.4")),
                .init("center", L("enum.position.topleft.5")),
            ]),
            .slider("opacity", L("image.watermark.param.opacity.label"), default: 80, min: 5, max: 100, step: 5),
            .number("margin", L("video.watermark.param.margin.label"), default: 24, min: 0, max: 500, step: 2),
        ],
        minimumInputs: 2,
        run: { context in
            // Last selected file is treated as the watermark source for images.
            let isImage = context.choice("kind", "text") == "image"
            let videos: [URL]
            let overlayImage: URL?
            if isImage {
                videos = context.inputs.filter { !$0.pathExtension.isImageExtension }
                overlayImage = context.inputs.last { $0.pathExtension.isImageExtension }
            } else {
                videos = context.inputs
                overlayImage = nil
            }
            guard let video = videos.first else {
                throw ProcessError.failed(code: 0, message: L("video.cover.param.format.label.4"))
            }
            if isImage && overlayImage == nil {
                throw ProcessError.failed(code: 0, message: L("video.watermark.param.margin.label.2"))
            }

            let duration = await MediaProbe.duration(video)
            let output = context.output(ext: video.pathExtension, suffix: L("image.watermark.param.margin.label.5"))
            let opacity = context.double("opacity", 80) / 100
            let margin = context.int("margin", 24)
            let position = context.choice("position", "bottomRight")

            // overlay filter expressions use main_w/main_h for the base frame
            // and overlay_w/overlay_h for the watermark layer.
            let xExpr: String, yExpr: String
            switch position {
            case "topLeft": xExpr = "\(margin)"; yExpr = "\(margin)"
            case "topRight": xExpr = "main_w-overlay_w-\(margin)"; yExpr = "\(margin)"
            case "bottomLeft": xExpr = "\(margin)"; yExpr = "main_h-overlay_h-\(margin)"
            case "center": xExpr = "(main_w-overlay_w)/2"; yExpr = "(main_h-overlay_h)/2"
            default: xExpr = "main_w-overlay_w-\(margin)"; yExpr = "main_h-overlay_h-\(margin)"
            }

            var inputArguments: [String] = ["-i", video.path]
            var args: [String] = []
            var filters: [String] = []
            // The local ffmpeg build has no drawtext filter, so text is
            // rasterised natively and composited as an image overlay.
            let scratch = try context.makeScratch()
            defer { FileIO.removeQuietly(scratch) }

            if isImage, let overlayImage {
                inputArguments += ["-i", overlayImage.path]
                let pct = context.double("imageScale", 20) / 100
                filters.append("[1:v]format=rgba,colorchannelmixer=aa=\(VideoSupport.fmt(opacity)),scale=iw*\(VideoSupport.fmt(pct)):-1[wm]")
                filters.append("[0:v][wm]overlay=\(xExpr):\(yExpr)[v]")
            } else {
                let rendered = try TextRenderer.renderPNG(
                    TextRenderer.Style(
                        text: context.string("text", "FormatForge"),
                        fontSize: context.double("fontSize", 32),
                        color: ImageSupport.nsColor(from: context.string("color", "white")),
                        opacity: opacity
                    ),
                    in: scratch)
                inputArguments += ["-i", rendered.url.path]
                let position = TextRenderer.overlayPosition(
                    position, size: rendered.size, margin: margin)
                filters.append("[1:v]format=rgba[wm]")
                filters.append("[0:v][wm]overlay=\(position.x):\(position.y)[v]")
            }

            args += ["-filter_complex", filters.joined(separator: ";")]
            args += ["-map", "[v]", "-map", "0:a?"]
            args += FFmpeg.videoArgs(codec: .h264, quality: 20,
                                     hardware: context.settings.useHardwareAcceleration,
                                     preset: "veryfast")
            args += ["-c:a", "copy"]

            return [try await VideoSupport.encode(
                context, input: video, output: output, arguments: args,
                duration: duration, inputArguments: inputArguments)]
        }
    ) }
}

// MARK: - 11. Metadata / MD5

enum VideoFingerprintTool {
    static var tool: Tool { Tool(
        id: "video.fingerprint",
        name: L("video.fingerprint.name"),
        summary: L("video.fingerprint.summary"),
        symbol: "number.circle",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "m4v", "avi"],
                requiresFFmpeg: true,
        actionTitle: L("video.fingerprint.action"),
        parameters: [
            .picker("mode", L("utility.rehash.param.method.label"), default: "both", options: [
                .init("metadata", L("video.fingerprint.param.mode.label"), detail: L("video.fingerprint.param.mode.label.2")),
                .init("remux", L("video.fingerprint.param.mode.label.3"), detail: L("video.fingerprint.param.mode.label.4")),
                .init("both", L("video.fingerprint.param.mode.label.5"), detail: L("video.fingerprint.param.mode.label.6")),
            ]),
            .text("tag", L("video.fingerprint.param.tag.label"), default: "",
                  hint: L("video.fingerprint.param.tag.hint")),
            .toggle("randomTitle", L("video.fingerprint.param.randomTitle.label"), default: true),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.fingerprint.param.randomTitle.label.2"))
                let mode = context.choice("mode", "both")
                let marker = context.string("tag", "").isEmpty
                    ? UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    : context.string("tag")

                var args: [String] = ["-c", "copy", "-map", "0"]

                if mode == "metadata" || mode == "both" {
                    args += ["-metadata", "comment=FormatForge-\(marker)"]
                    if context.bool("randomTitle", true) {
                        args += ["-metadata", "title=\(marker.prefix(12))"]
                    }
                }
                if mode == "remux" || mode == "both" {
                    // Re-laying out the container alone changes the byte stream.
                    args += ["-movflags", "+faststart"]
                    args += ["-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
                }

                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration))
            }
            return outputs
        }
    ) }
}

// MARK: - 12. Strip metadata

enum VideoMetadataStripTool {
    static var tool: Tool { Tool(
        id: "video.strip",
        name: L("video.strip.name"),
        summary: L("video.strip.summary"),
        symbol: "eye.slash",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "m4v", "avi"],
                requiresFFmpeg: true,
        actionTitle: L("video.strip.action"),
        parameters: [
            .toggle("keepRotation", L("video.strip.param.keepRotation.label"), default: true,
                    hint: L("video.strip.param.keepRotation.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.strip.param.keepRotation.label.2"))
                var args = ["-c", "copy", "-map", "0", "-map_metadata", "-1"]
                if context.bool("keepRotation", true) {
                    let rotation = await MediaProbe.info(for: input)?.rotation ?? 0
                    if rotation != 0 {
                        args += ["-metadata:s:v:0", "rotate=\(rotation)"]
                    }
                }
                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration))
            }
            return outputs
        }
    ) }
}

// MARK: - 13. Resize only

enum VideoResizeTool {
    static var tool: Tool { Tool(
        id: "video.resize",
        name: L("video.resize.name"),
        summary: L("video.resize.summary"),
        symbol: "arrow.up.left.and.arrow.down.right",
        category: .video,
        accepts: ["mp4", "mov", "mkv", "avi", "webm", "m4v"],
                requiresFFmpeg: true,
        actionTitle: L("video.resize.action"),
        parameters: [
            .picker("scale", L("video.resize.param.scale.label"), default: "p1080", options: VideoOptions.scale),
            .number("customWidth", L("image.resize.param.width.label"), default: 1920, min: 16, max: 7680,
                    visibleWhen: .equals("scale", "custom")),
            .number("customHeight", L("image.resize.param.height.label"), default: 1080, min: 16, max: 7680,
                    visibleWhen: .equals("scale", "custom")),
            .picker("fit", L("image.resize.param.fit.label"), default: "fit", options: [
                .init("fit", L("video.resize.param.fit.label")),
                .init("fill", L("video.resize.param.fit.label.2")),
                .init("stretch", L("video.resize.param.fit.label.3")),
            ], visibleWhen: .equals("scale", "custom")),
            .toggle("allowUpscale", L("video.resize.param.allowUpscale.label"), default: false),
            .slider("crf", L("video.fromimages.param.crf.label"), default: 20, min: 14, max: 34, step: 1),
        ],
        run: { context in
            var outputs: [URL] = []
            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let duration = await MediaProbe.duration(input)
                let output = context.output(index: index, ext: input.pathExtension, suffix: L("video.resize.param.crf.label"))

                var filters: [String] = []
                let scale = ScalePreset(rawValue: context.choice("scale", "p1080")) ?? .p1080
                let fit = context.choice("fit", "fit")
                let allowUpscale = context.bool("allowUpscale", false)

                switch scale {
                case .custom:
                    // An explicit box is the only case where fit modes are
                    // meaningful; the presets are proportional by definition.
                    let width = context.int("customWidth", 1920)
                    let height = context.int("customHeight", 1080)
                    let boxW = allowUpscale ? "\(width)" : "min(\(width)\\,iw)"
                    let boxH = allowUpscale ? "\(height)" : "min(\(height)\\,ih)"
                    switch fit {
                    case "fill":
                        // Cover the box, then crop the overflow so nothing distorts.
                        filters.append("scale=\(boxW):\(boxH):force_original_aspect_ratio=increase")
                        filters.append("crop=\(boxW):\(boxH)")
                    case "stretch":
                        filters.append("scale=\(boxW):\(boxH)")
                    default:
                        filters.append("scale=\(boxW):\(boxH):force_original_aspect_ratio=decrease")
                    }
                case .original:
                    break
                default:
                    if let height = scale.height {
                        // min(h,ih) prevents accidental upscaling.
                        let target = allowUpscale ? "\(height)" : "min(\(height)\\,ih)"
                        filters.append("scale=-2:\(target)")
                    }
                }
                var args: [String] = []
                if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
                args += FFmpeg.videoArgs(codec: .h264, quality: context.double("crf", 20),
                                         hardware: context.settings.useHardwareAcceleration,
                                         preset: "medium")
                args += ["-c:a", "copy"]
                if output.pathExtension == "mp4" { args += ["-movflags", "+faststart"] }

                outputs.append(try await VideoSupport.encode(
                    context, input: input, output: output,
                    arguments: args, duration: duration))
            }
            return outputs
        }
    ) }
}
