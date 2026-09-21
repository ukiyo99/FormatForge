import Foundation

// A headless driver that executes the *real* tool implementations, so the
// conversion engines are verified against real media rather than just compiled.
//
//   harness <toolID> <outputDir> [--preset id] [--estimate] [--param k=v]... [--] <input>...
//
// Exits non-zero and prints a diagnostic when a tool fails.

@main
struct Harness {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: harness <toolID> <outDir> [--param k=v]... [--] <inputs>\n".utf8))
            exit(2)
        }

        let toolID = arguments.removeFirst()
        let outputDir = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)

        var values: [String: ParameterValue] = [:]
        var inputs: [URL] = []
        var parsingParams = true
        var presetID: String?
        var showEstimate = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { parsingParams = false; continue }
            if parsingParams, argument == "--preset" {
                presetID = index < arguments.count ? arguments[index] : nil
                index += 1
                continue
            }
            if parsingParams, argument == "--estimate" {
                showEstimate = true
                continue
            }
            if parsingParams, argument.hasPrefix("--param") { continue }
            if parsingParams, argument.hasPrefix("--") { continue }
            if parsingParams, let range = argument.range(of: "="), !argument.hasPrefix("/") {
                let key = String(argument[argument.startIndex..<range.lowerBound])
                let raw = String(argument[range.upperBound...])
                values[key] = parse(raw)
                continue
            }
            inputs.append(URL(fileURLWithPath: argument))
        }

        guard let tool = ToolRegistry.tool(withID: toolID) else {
            fail("unknown tool id: \(toolID)")
        }

        // Seed unspecified parameters with the tool defaults, then layer the
        // preset (if any) and finally the explicit overrides.
        var merged = ToolSession.defaults(for: tool)
        if let presetID {
            guard let preset = Presets.ladder(for: toolID).first(where: { $0.id == presetID }) else {
                fail("unknown preset '\(presetID)' for \(toolID); available: "
                     + Presets.ladder(for: toolID).map(\.id).joined(separator: ", "))
            }
            for (key, value) in preset.values { merged[key] = value }
            print("PRESET  \(preset.label) — \(preset.detail)")
        }
        for (key, value) in values { merged[key] = value }

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // The GIF builder reads its recipe from a shared box.
        if toolID == "image.gif" {
            let frames = inputs.map { GifRecipe.Frame(url: $0, duration: 0.2) }
            GifRecipeBox.shared.recipe = GifRecipe(
                frames: frames,
                width: Int(merged["width"]?.doubleValue ?? 320),
                fit: .contain,
                background: (0, 0, 0),
                loopCount: 0,
                transition: .fade,
                transitionFrames: 3,
                colorCount: 128,
                dither: false,
                reverse: false
            )
        }

        // Surface the estimate the way the UI does, so it can be asserted on.
        var estimate: WorkEstimate?
        if showEstimate || true {
            let result = await EstimateEngine.compute(
                toolID: toolID, inputs: inputs, values: merged, settings: AppSettings.shared)
            estimate = result.estimate
            if showEstimate, let estimate {
                print("ESTIMATE  size=\(estimate.sizeLabel)  time=\(estimate.timeLabel)"
                      + "  basis=\(estimate.basis)"
                      + "  bytes=\(estimate.outputBytes ?? -1)"
                      + "  seconds=\(String(format: "%.2f", estimate.seconds ?? -1))")
            } else {
                print("ESTIMATE  none")
            }
        }

        // Mirror the app: log every line so the log pipeline is exercised.
        let logger = JobLogger { entry in
            print("    [\(entry.level.rawValue)] \(entry.text)")
        }

        let context = ToolContext(
            toolID: toolID,
            inputs: inputs,
            outputDirectory: outputDir,
            values: merged,
            settings: AppSettings.shared,
            progress: ProgressReporter { fraction, note in
                if let note { print("    · \(note)") }
            },
            handle: ProcessHandle(),
            logger: logger
        )

        JobLifecycle.logStart(
            logger, toolName: tool.name, inputs: inputs,
            outputDirectory: outputDir, estimate: estimate)

        let start = Date()
        do {
            let outputs = try await tool.run(context)
            let elapsed = Date().timeIntervalSince(start)
            if outputs.isEmpty && !tool.writesFiles(values: merged) {
                // Report-only tools legitimately produce nothing; the findings
                // were already streamed to the log above.
                logger.success("Inspection complete; see the log above")
                logger.info(String(format: "Took %.2f s", elapsed))
            } else {
                JobLifecycle.logSuccess(
                    logger, outputs: outputs,
                    inputBytes: inputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) },
                    elapsed: elapsed)
            }
            print("OK  \(toolID)  [\(outputs.count) outputs, \(String(format: "%.2f", elapsed))s]")
            for url in outputs {
                let size = FileIO.size(of: url)
                print("    → \(url.path)  (\(Format.bytes(size)))")
            }
            exit(0)
        } catch {
            logger.error(error.localizedDescription)
            fail("\(toolID) failed: \(error.localizedDescription)")
        }
    }

    private static func parse(_ raw: String) -> ParameterValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let number = Double(raw) { return .number(number) }
        return .text(raw)
    }

    private static func fail(_ message: String) -> Never {
        print("FAIL  \(message)")
        exit(1)
    }
}
