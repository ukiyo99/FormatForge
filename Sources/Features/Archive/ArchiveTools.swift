import Foundation

// MARK: - Archive format

enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tar
    case tarBz2 = "tar.bz2"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7Z"
        case .tarGz: return "TAR.GZ"
        case .tar: return "TAR"
        case .tarBz2: return "TAR.BZ2"
        }
    }

    var detail: String {
        switch self {
        case .zip: return L("enum.archive.tarbz2")
        case .sevenZip: return L("enum.archive.tarbz2.2")
        case .tarGz: return L("enum.archive.tarbz2.3")
        case .tar: return L("preset.store.label")
        case .tarBz2: return L("enum.archive.tarbz2.4")
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tarGz: return "tar.gz"
        case .tar: return "tar"
        case .tarBz2: return "tar.bz2"
        }
    }

    /// Whether the format supports password protection.
    var supportsPassword: Bool {
        self == .zip || self == .sevenZip
    }

    /// Whether encrypted filenames are supported (7z only).
    var supportsEncryptedNames: Bool { self == .sevenZip }

    /// Compression level 0–9.
    var defaultLevel: Double {
        switch self {
        case .zip, .sevenZip: return 5
        case .tar: return 0
        default: return 6
        }
    }
}

// MARK: - Create

enum ArchiveCreateTool {
    static var tool: Tool { Tool(
        id: "archive.create",
        name: L("archive.create.name"),
        summary: L("archive.create.summary"),
        symbol: "archivebox",
        category: .archive,
        accepts: [],
        requiresSevenZip: true,
        actionTitle: L("archive.create.action"),
        parameters: [
            .picker("format", L("archive.create.param.format.label"), default: "zip", options: ArchiveFormat.allCases.map {
                PickerOption($0.rawValue, $0.label, detail: $0.detail)
            }),
            .text("name", L("archive.create.param.name.label"), default: L("archive.create.param.name.label.2")),
            .slider("level", L("archive.create.param.level.label"), default: 5, min: 0, max: 9, step: 1,
                    hint: L("archive.create.param.level.hint")),
            .picker("volumeMode", L("archive.create.param.volumeMode.label"), default: "none", options: [
                .init("none", L("archive.create.param.volumeMode.label.2")), .init("preset", L("archive.create.param.volumeMode.label.3")), .init("count", L("archive.create.param.volumeMode.label.4")),
            ]),
            .picker("volumeSize", L("archive.create.param.volumeSize.label"), default: "100m", options: [
                .init("10m", "10 MB"), .init("50m", "50 MB"), .init("100m", "100 MB"),
                .init("500m", "500 MB"), .init("1000m", "1 GB"), .init("2000m", "2 GB"),
            ], visibleWhen: .equals("volumeMode", "preset")),
            .number("volumeCount", L("archive.create.param.volumeCount.label"), default: 3, min: 2, max: 200, step: 1,
                    visibleWhen: .equals("volumeMode", "count")),
            .text("password", L("archive.create.param.password.label"), default: "",
                  hint: L("archive.create.param.password.hint")),
            .toggle("encryptNames", L("archive.create.param.encryptNames.label"), default: true,
                    hint: L("archive.create.param.encryptNames.hint")),
            .toggle("storePaths", L("archive.create.param.storePaths.label"), default: true),
        ],
        run: { context in
            guard !context.inputs.isEmpty else {
                throw ProcessError.failed(code: 0, message: L("archive.create.param.storePaths.label.2"))
            }
            let format = ArchiveFormat(rawValue: context.choice("format", "zip")) ?? .zip
            let baseName = FileIO.sanitize(context.string("name", L("archive.create.param.name.label.2")))
            let password = context.string("password", "")
            let level = context.int("level", 5)

            guard ProcessRunner.exists("7z") || format == .zip else {
                throw ProcessError.failed(code: 0, message: L("archive.create.param.storePaths.label.3"))
            }
            if !password.isEmpty && !format.supportsPassword {
                throw ProcessError.failed(code: 0, message: L("archive.create.param.storePaths.label.4", format.label))
            }

            let archiveURL = context.output("\(baseName).\(format.fileExtension)")

            // Resolve the volume size.
            var volumeArgument: String?
            switch context.choice("volumeMode", "none") {
            case "preset":
                volumeArgument = context.choice("volumeSize", "100m")
            case "count":
                let count = max(context.int("volumeCount", 3), 2)
                let total = context.inputs.reduce(Int64(0)) { $0 + directorySize($1) }
                // Compression typically saves ~35%; leave headroom.
                let estimated = Int64(Double(total) * 0.75)
                let perVolume = max(estimated / Int64(count), 1024 * 1024)
                volumeArgument = "\(perVolume)b"
            default:
                volumeArgument = nil
            }

            let args = try buildArguments(
                context: context, format: format, archiveURL: archiveURL,
                level: level, password: password, volume: volumeArgument)

            context.progress.note(L("archive.create.param.storePaths.label.5"))
            context.logger.info(L("archive.create.param.storePaths.label.6", context.inputs.count, archiveURL.lastPathComponent))
            let result = try await ProcessRunner.runLogged(
                "7z", args, handle: context.handle, logger: context.logger,
                onStdout: { line in
                    // 7z prints progress as percentages on stdout.
                    if let range = line.range(of: "%") {
                        let prefix = line[line.startIndex..<range.lowerBound]
                            .trimmingCharacters(in: .whitespaces)
                        if let value = Double(prefix) {
                            context.progress.report(value / 100)
                        }
                    }
                })

            if result.cancelled { throw ProcessError.cancelled }
            guard result.exitCode == 0 else {
                throw ProcessError.failed(code: result.exitCode, message: result.stderr + result.stdout)
            }

            // Collect the produced volumes (or the single archive).
            let directory = archiveURL.deletingLastPathComponent()
            let prefix = archiveURL.lastPathComponent
            let produced = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            context.progress.report(1)
            return produced.isEmpty ? [archiveURL] : produced
        }
    ) }

    private static func buildArguments(
        context: ToolContext, format: ArchiveFormat, archiveURL: URL,
        level: Int, password: String, volume: String?
    ) throws -> [String] {
        var args = ["a", "-y", "-bsp1"]

        switch format {
        case .zip:
            args += ["-tzip"]
            if password.isEmpty {
                // Plain ZIP is better served by the system zip tool.
                args += ["-mx=\(level)"]
            } else {
                args += ["-mx=\(level)", "-p\(password)", "-mem=AES256"]
            }
        case .sevenZip:
            args += ["-t7z", "-mx=\(level)"]
            if !password.isEmpty {
                args += ["-p\(password)"]
                if context.bool("encryptNames", true) { args += ["-mhe=on"] }
            }
        case .tarGz:
            args += ["-tgzip", "-mx=\(level)"]
        case .tar:
            args += ["-ttar"]
        case .tarBz2:
            args += ["-tbzip2", "-mx=\(level)"]
        }

        if let volume { args += ["-v\(volume)"] }
        if !context.bool("storePaths", true) { args += ["-spf2"] }
        args += [archiveURL.path]

        // Pass every input path; 7z handles files and folders alike.
        for input in context.inputs {
            args += [input.path]
        }
        return args
    }

    /// Recursive size used to estimate the volume split.
    static func directorySize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return FileIO.size(of: url) }

        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let child as URL in enumerator {
                guard let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true
                else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Extract

enum ArchiveExtractTool {

    /// Strip archive suffixes so `movie.7z.001` yields `movie`, not `movie.7z`.
    static func archiveBaseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        let compound = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz"]
        for suffix in compound where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            return name.isEmpty ? url.lastPathComponent : name
        }
        // Numeric volume suffixes: .001, .part1, .r00 …
        if let range = name.range(of: #"\.(7z|zip|rar|tar|gz|bz2|xz)?\.?\d{3}$"#,
                                 options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        } else if let range = name.range(of: #"\.part\d+$"#, options: .regularExpression) {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        if let dot = name.lastIndex(of: "."), name.distance(from: name.startIndex, to: dot) > 0 {
            let ext = name[name.index(after: dot)...].lowercased()
            if ["7z", "zip", "rar", "tar", "gz", "bz2", "xz"].contains(ext) {
                name = String(name[name.startIndex..<dot])
            }
        }
        return name.isEmpty ? url.lastPathComponent : name
    }

    static var tool: Tool { Tool(
        id: "archive.extract",
        name: L("archive.extract.name"),
        summary: L("archive.extract.summary"),
        symbol: "archivebox.and.arrow.down",
        category: .archive,
        accepts: ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "001"],
        requiresSevenZip: true,
        actionTitle: L("archive.extract.action"),
        parameters: [
            .text("password", L("archive.extract.param.password.label"), default: ""),
            .toggle("toSubfolder", L("archive.extract.param.toSubfolder.label"), default: true),
            .text("subfolderName", L("archive.extract.param.subfolderName.label"), default: ""),
            .toggle("overwrite", L("archive.extract.param.overwrite.label"), default: false),
        ],
        run: { context in
            var outputs: [URL] = []
            guard ProcessRunner.exists("7z") else {
                throw ProcessError.failed(code: 0, message: L("archive.extract.param.overwrite.label.2"))
            }

            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()

                let folderName = context.string("subfolderName", "")
                let baseName = folderName.isEmpty
                    ? ArchiveExtractTool.archiveBaseName(input)
                    : FileIO.sanitize(folderName)

                let destination: URL
                if context.bool("toSubfolder", true) {
                    destination = context.outputDirectory.appendingPathComponent(baseName, isDirectory: true)
                } else {
                    destination = context.outputDirectory
                }
                try FileIO.ensureDirectory(destination)

                var args = ["x", "-bsp1", "-o\(destination.path)"]
                if context.bool("overwrite") { args += ["-aoa"] } else { args += ["-aos"] }
                let password = context.string("password", "")
                if !password.isEmpty { args += ["-p\(password)"] }
                args += [input.path]

                context.progress.note(L("archive.extract.param.overwrite.label.3", input.lastPathComponent))
                context.logger.info(L("archive.extract.param.overwrite.label.4", destination.path))
                let result = try await ProcessRunner.runLogged(
                    "7z", args, handle: context.handle, logger: context.logger,
                    onStdout: { line in
                        if let range = line.range(of: "%") {
                            let prefix = line[line.startIndex..<range.lowerBound]
                                .trimmingCharacters(in: .whitespaces)
                            if let value = Double(prefix) { context.progress.report(value / 100) }
                        }
                    })

                if result.cancelled { throw ProcessError.cancelled }
                guard result.exitCode == 0 else {
                    let combined = result.stdout + result.stderr
                    if combined.contains("Wrong password") || combined.contains("password") {
                        throw ProcessError.failed(code: result.exitCode, message: L("archive.extract.param.overwrite.label.5"))
                    }
                    throw ProcessError.failed(code: result.exitCode, message: combined)
                }
                outputs.append(destination)
                context.progress.report(Double(index + 1) / Double(context.inputs.count))
            }
            return outputs
        }
    ) }
}
