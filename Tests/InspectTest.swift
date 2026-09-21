import Foundation

@main struct T {
    static var failures = 0
    static func check(_ c: Bool, _ label: String) {
        print("  \(c ? "✓" : "✗") \(label)")
        if !c { failures += 1 }
    }

    static func main() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = root.appendingPathComponent(".test/fixtures")

        // 1) All five checksums from one pass, matching the system tools.
        print("=== 1) Checksums (one read, all algorithms) ===")
        let file = fixture.appendingPathComponent("clip.mp4")
        let result = HashEngine.hash(file, algorithms: HashAlgorithm.allCases)
        check(result.ok, "Computed successfully")
        for algo in HashAlgorithm.allCases {
            guard let value = result.values[algo] else {
                check(false, "\(algo.label) missing"); continue
            }
            check(value.count == algo.hexLength,
                  "\(algo.label) = \(value.prefix(16))… (\(value.count) hex digits)")
        }

        // Cross-check against the system tools.
        func system(_ tool: String, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Trim whitespace/newlines: `md5 -q` emits a bare hash + newline,
            // while `shasum` emits "hash  filename".
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init) ?? ""
        }
        check(result.values[.md5] == system("/sbin/md5", ["-q", file.path]),
              "MD5 matches the system md5")
        check(result.values[.sha256] == system("/usr/bin/shasum", ["-a", "256", file.path]),
              "SHA-256 matches the system shasum")
        check(result.values[.sha1] == system("/usr/bin/shasum", ["-a", "1", file.path]),
              "SHA-1 matches the system shasum")

        // CRC32 cross-check via python.
        let crcExpect = system("/usr/bin/python3", ["-c", """
import zlib,sys
print('%08x' % (zlib.crc32(open(sys.argv[1],'rb').read()) & 0xffffffff))
""", file.path])
        check(result.values[.crc32] == crcExpect, "CRC32 = \(result.values[.crc32] ?? "?")")

        // 2) Verification against an expected value.
        print()
        print("=== 2) Checksum comparison ===")
        let good = HashEngine.verify(file, expected: result.values[.sha256]!, algorithm: .sha256)
        let bad = HashEngine.verify(file, expected: String(repeating: "0", count: 64), algorithm: .sha256)
        check(good == true, "A correct checksum is reported as matching")
        check(bad == false, "A wrong checksum is reported as mismatching")

        // 3) Inspection tools need no button and no output folder.
        print()
        print("=== 3) Inspectors run automatically ===")
        await MainActor.run {
            for id in ["utility.hash", "utility.info", "archive.info"] {
                guard let tool = ToolRegistry.tool(withID: id) else {
                    check(false, "\(id) not found"); continue
                }
                check(tool.isInspection, "\(tool.name): automatic")
                check(!tool.needsRunButton, "\(tool.name): no button")
                check(!tool.writesFiles, "\(tool.name): no output folder")
                check(tool.inspector != nil, "\(tool.name): has an inspector")
            }
        }

        // 4) The image inspector must produce rich metadata.
        print()
        print("=== 4) Image info completeness ===")
        let image = fixture.appendingPathComponent("photo.jpg")
        let report = await ImageInspector().inspect(inputs: [image], values: [:]) { _ in }
        check(report.error == nil, "No error")
        let total = report.sections.reduce(0) { $0 + $1.rows.count }
        check(total >= 10, "\(report.sections.count) sections, \(total) rows of information")
        for section in report.sections {
            print("      · \(section.title) (\(section.rows.count) rows)")
        }
        let hasTimeline = report.sections
            .flatMap(\.rows)
            .contains { ["Duration", "Frame rate", "Bitrate"].contains($0.label) }
        check(!hasTimeline, "Image info omits duration, frame rate and bitrate")

        print()
        print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
