import Foundation

// Verify that adding files alone produces a report — no button press.
@main struct T {
    static func main() async {
        let state = await AppState()
        let tool = await MainActor.run { ToolRegistry.tool(withID: "utility.hash")! }
        await MainActor.run { state.select(tool) }

        let initial = await MainActor.run { state.report == nil }
        print("Initial state: report=\(initial ? "nil" : "present")")

        // Adding a file is the ONLY action taken.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test/fixtures/clip.mp4")
        await MainActor.run { state.addInputs([url]) }

        let inspecting = await MainActor.run { state.isInspecting }
        print("After dropping a file (no button clicked): isInspecting=\(inspecting)")

        // The computation runs off the main actor; poll without blocking it.
        var waited = 0.0
        while await MainActor.run(body: { state.report == nil }) && waited < 15 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }

        let report = await MainActor.run { state.report }
        if let report {
            let rows = report.sections.flatMap(\.rows)
            print("Generated automatically: \(report.sections.count) sections, \(rows.count) rows")
            for row in rows where row.mono {
                print("    \(row.label) = \(row.value)")
            }
            let hashes = rows.filter {
                ["MD5", "SHA-1", "SHA-256", "SHA-512", "CRC32"].contains($0.label)
            }
            print(hashes.count == 5
                  ? "RESULT PASS — dropping a file computed all \(hashes.count) checksums"
                  : "RESULT FAIL — only \(hashes.count) computed")
            exit(hashes.count == 5 ? 0 : 1)
        } else {
            print("RESULT FAIL — dropping a file did not generate a report")
            exit(1)
        }
    }
}
