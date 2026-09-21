import Foundation

/// Inspection tools.
///
/// These are deliberately *not* conversion tools: they have no Run button, do
/// not enter the task queue, and never ask for an output folder. Their results
/// appear inline the moment files are added, and update as options change.
enum InspectTools {

    // MARK: Checksums

    static var hash: Tool { Tool(
        id: "utility.hash",
        name: L("utility.hash.name"),
        summary: L("utility.hash.summary"),
        symbol: "number",
        category: .utility,
        accepts: [],
        resultKind: .report,
        parameters: [
            .text("expected", L("utility.hash.param.expected.label"), default: "",
                  hint: L("utility.hash.param.expected.hint")),
            .picker("verifyAlgorithm", L("utility.hash.param.verifyAlgorithm.label"), default: "sha256", options: [
                .init("md5", "MD5"), .init("sha1", "SHA-1"), .init("sha256", "SHA-256"),
                .init("sha512", "SHA-512"), .init("crc32", "CRC32"),
            ]),
        ],
        inspector: HashInspector(),
        run: { _ in [] }
    ) }

    // MARK: Image metadata

    static var imageInfo: Tool { Tool(
        id: "utility.info",
        name: L("utility.info.name"),
        summary: L("utility.info.summary"),
        symbol: "info.circle",
        category: .utility,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "heif",
                  "webp", "gif", "avif", "ico", "icns", "psd", "jp2", "exr", "dng"],
        resultKind: .report,
        parameters: [
            .toggle("extractPalette", L("utility.info.param.extractPalette.label"), default: true,
                    hint: L("utility.info.param.extractPalette.hint")),
        ],
        inspector: ImageInspector(),
        run: { _ in [] }
    ) }

    // MARK: Archive contents

    static var archiveInfo: Tool { Tool(
        id: "archive.info",
        name: L("archive.info.name"),
        summary: L("archive.info.summary"),
        symbol: "list.bullet.rectangle",
        category: .archive,
        accepts: ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "001"],
        requiresSevenZip: true,
        resultKind: .report,
        parameters: [
            .text("password", L("archive.extract.param.password.label"), default: ""),
        ],
        inspector: ArchiveInspector(),
        run: { _ in [] }
    ) }

    static let all: [Tool] = [hash, imageInfo, archiveInfo]
}

// MARK: - Archive inspector

/// Lists archive contents without extracting anything.
struct ArchiveInspector: FileInspector {
    func inspect(
        inputs: [URL],
        values: [String: ParameterValue],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> InspectionReport {
        guard ProcessRunner.exists("7z") else {
            return .failure(L("archive.info.param.password.label"))
        }

        var sections: [InspectionReport.Section] = []
        let password = values["password"]?.stringValue ?? ""

        for (index, url) in inputs.enumerated() {
            progress(Double(index) / Double(max(inputs.count, 1)))

            var args = ["l", "-slt"]
            if !password.isEmpty { args += ["-p\(password)"] }
            args += [url.path]

            guard let result = try? await ProcessRunner.run("7z", args) else {
                sections.append(.init(id: url.path, title: url.lastPathComponent,
                                      symbol: "xmark.circle", rows: [], note: L("archive.info.param.password.label.2")))
                continue
            }
            guard result.exitCode == 0 else {
                let message = (result.stdout + result.stderr)
                    .contains("password") ? L("archive.extract.param.overwrite.label.5") : L("archive.info.param.password.label.2")
                sections.append(.init(id: url.path, title: url.lastPathComponent,
                                      symbol: "lock", rows: [], note: message))
                continue
            }

            // Parse the -slt key/value listing.
            var entries: [(path: String, size: Int64, packed: Int64, encrypted: Bool)] = []
            var currentPath: String?
            var size: Int64 = 0
            var packed: Int64 = 0
            var encrypted = false

            func flush() {
                if let path = currentPath {
                    entries.append((path, size, packed, encrypted))
                }
                currentPath = nil; size = 0; packed = 0; encrypted = false
            }

            for line in result.stdout.split(separator: "\n") {
                let text = String(line)
                if text.hasPrefix("Path = ") {
                    flush()
                    currentPath = String(text.dropFirst(7))
                } else if text.hasPrefix("Size = ") {
                    size = Int64(text.dropFirst(7)) ?? 0
                } else if text.hasPrefix("Packed Size = ") {
                    packed = Int64(text.dropFirst(14)) ?? 0
                } else if text.hasPrefix("Encrypted = ") {
                    encrypted = text.contains("+")
                }
            }
            flush()

            // Drop the archive's own entry if 7z reports it.
            let files = entries.filter { $0.path != url.path && !$0.path.isEmpty }
            let totalSize = files.reduce(Int64(0)) { $0 + $1.size }
            let totalPacked = files.reduce(Int64(0)) { $0 + $1.packed }

            var rows: [InspectionReport.Row] = [
                .init(id: "count", label: L("archive.info.param.password.label.3"), value: "\(files.count)", mono: true),
                .init(id: "raw", label: L("archive.info.param.password.label.4"), value: Format.bytes(totalSize), mono: true),
                .init(id: "packed", label: L("archive.info.param.password.label.5"),
                      value: totalPacked > 0 ? Format.bytes(totalPacked)
                                             : Format.bytes(FileIO.size(of: url)),
                      mono: true),
            ]
            if totalSize > 0, totalPacked > 0 {
                let saved = 1 - Double(totalPacked) / Double(totalSize)
                rows.append(.init(id: "ratio", label: L("enum.codec.h264.15"),
                                  value: String(format: L("archive.info.param.password.label.6"), saved * 100),
                                  status: .ok))
            }
            if files.contains(where: \.encrypted) {
                rows.append(.init(id: "enc", label: L("doc.pdfsecurity.param.action.label.2"), value: L("archive.info.param.password.label.7"),
                                  status: .neutral))
            }
            sections.append(.init(id: "summary-\(url.path)", title: L("archive.info.param.password.label.8"),
                                  symbol: "archivebox", rows: rows))

            // List the contents, capped so a huge archive stays readable.
            let preview = files.prefix(300)
            let contentRows = preview.map { entry -> InspectionReport.Row in
                let sizeText = Format.bytes(entry.size)
                return .init(id: entry.path, label: sizeText, value: entry.path, mono: true)
            }
            sections.append(.init(
                id: "list-\(url.path)",
                title: L("archive.info.param.password.label.9"),
                symbol: "list.bullet",
                rows: Array(contentRows),
                note: files.count > preview.count
                    ? L("archive.info.param.password.label.10", preview.count, files.count)
                    : nil))
        }

        progress(1)
        return InspectionReport(sections: sections, summary: L("archive.info.summary.2", inputs.count))
    }
}
