import Foundation

// Verify that changing the language actually changes the strings the main UI
// reads — not just the settings pane — and that parameter values behave
// correctly across a switch.
//
// This exists because of a real bug: the tool definitions were `static let`, so
// Swift evaluated them once and the translated strings were frozen. Changing
// the language updated Settings but left the whole workspace in the old
// language.
@main struct T {
    static var failures = 0
    static func check(_ c: Bool, _ label: String) {
        print("  \(c ? "✓" : "✗") \(label)")
        if !c { failures += 1 }
    }

    static func main() async {
        await MainActor.run {
            let state = AppState()

            // Pick a tool and note its name in English.
            guard let compress = ToolRegistry.tool(withID: "video.compress") else {
                check(false, "video.compress not found"); return
            }
            state.select(compress)
            let englishName = state.selectedTool.name
            let englishLabel = state.selectedTool.parameters.first?.label ?? ""

            // Switch to German.
            state.setLanguage(.german)
            let germanName = state.selectedTool.name
            let germanLabel = state.selectedTool.parameters.first?.label ?? ""

            print("  Tool name: \(englishName) → \(germanName)")
            print("  Parameter: \(englishLabel) → \(germanLabel)")

            check(englishName != germanName, "Tool name changes with the language")
            check(englishLabel != germanLabel, "Parameter label changes with the language")
            check(germanName != "video.compress.name", "Did not fall back to the key")

            // Now verify an edited value survives a switch.
            state.select(compress)
            state.setLanguage(.english)
            state.session.parameterValues["crf"] = .number(17)
            state.setLanguage(.japanese)
            let kept = state.session.parameterValues["crf"]?.doubleValue
            check(kept == 17, "An edited value survives a language switch (crf=\(kept ?? -1))")

            // And a translated *default* follows the language.
            guard let rename = ToolRegistry.tool(withID: "image.rename") else {
                check(false, "image.rename not found"); return
            }
            state.select(rename)
            state.setLanguage(.english)
            let patternEN = state.session.parameterValues["pattern"]?.stringValue ?? ""
            state.setLanguage(.chineseSimplified)
            let patternZH = state.session.parameterValues["pattern"]?.stringValue ?? ""
            print("  Rename template: \(patternEN) → \(patternZH)")
            check(patternEN != patternZH, "An untouched default follows the language")

            state.setLanguage(.english)
            print()
            print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
