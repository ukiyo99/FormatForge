import Foundation

// Verify that each tool keeps independent state, so a long job in one tool
// never blocks or interferes with another.
@main struct T {
    static func main() async {
        await MainActor.run {
            let state = AppState()
            let tools = ToolRegistry.all
            print("Total tools: \(tools.count)")

            // Stage different files in three different tools. The files must
            // really exist: FileIO.expand drops paths that are not on disk, so
            // fake ones would be silently ignored.
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("formatforge-session-test")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            func touch(_ name: String) -> URL {
                let url = scratch.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
                }
                return url
            }
            let aURL = touch("a.mp4"), bURL = touch("b.mp4"), cURL = touch("c.jpg")

            let a = tools.first { $0.id == "video.compress" }!
            let b = tools.first { $0.id == "utility.hash" }!
            let c = tools.first { $0.id == "image.convert" }!

            state.select(a)
            state.addInputs([aURL])
            state.session.applyPreset(id: "extreme")

            state.select(b)
            state.addInputs([bURL])
            state.session.parameterValues["algorithm"] = .text("sha256")

            state.select(c)
            state.addInputs([cURL])

            // Now revisit each tool and confirm its state survived.
            state.select(a)
            let aOK = state.inputs.map(\.lastPathComponent) == ["a.mp4"]
                && state.session.selectedPresetID == "extreme"

            state.select(b)
            let bOK = state.inputs.map(\.lastPathComponent) == ["b.mp4"]
                && state.session.parameterValues["algorithm"]?.stringValue == "sha256"

            state.select(c)
            let cOK = state.inputs.map(\.lastPathComponent) == ["c.jpg"]

            print("Video compression keeps its preset and inputs: \(aOK ? "✓" : "✗")")
            print("Change hash keeps separate inputs and parameters: \(bOK ? "✓" : "✗")")
            print("Image conversion keeps separate inputs: \(cOK ? "✓" : "✗")")

            // Sidebar badges should reflect staged work per tool.
            let stagedA = state.stagedInputs(for: "video.compress")
            let stagedB = state.stagedInputs(for: "utility.hash")
            print("Category badge counts: video.compress=\(stagedA) utility.hash=\(stagedB)")
            print("Staged count in category: \(state.stagedCount(in: .utility))")

            let allOK = aOK && bOK && cOK && stagedA == 1 && stagedB == 1
            print(allOK ? "RESULT PASS" : "RESULT FAIL")
            exit(allOK ? 0 : 1)
        }
    }
}
