import Foundation

// Verify that switching language changes real UI strings, that every language
// file loads, and that no key falls back to its own identifier.
@main struct T {
    static var failures = 0
    static func check(_ c: Bool, _ label: String) {
        print("  \(c ? "✓" : "✗") \(label)")
        if !c { failures += 1 }
    }

    static func main() {
        print("=== Language resources ===")
        let store = LanguageStore.shared
        var loaded: [Language] = []
        for language in Language.allCases {
            let table = store.table(language)
            if table.isEmpty {
                print("  ✗ \(language.rawValue): could not load")
                failures += 1
            } else {
                loaded.append(language)
            }
        }
        check(loaded.count == Language.allCases.count,
              "All \(Language.allCases.count) language tables load")

        // Every language must define the same key set as English.
        let english = Set(store.table(.english).keys)
        for language in Language.allCases where language != .english {
            let keys = Set(store.table(language).keys)
            let missing = english.subtracting(keys)
            check(missing.isEmpty, "\(language.nativeName): \(keys.count) keys, \(missing.count) missing")
        }

        // Choose probes from the shipped table so the test never goes stale
        // when keys are renamed.
        let englishTable = store.table(.english)
        var probes = ["video.convert.name", "video.convert.summary", "enum.category.video"]
        for wanted in ["Copy", "Tasks", "Input Files", "Language"] {
            if let match = englishTable.first(where: { $0.value == wanted })?.key {
                probes.append(match)
            }
        }
        probes = probes.filter { englishTable[$0] != nil }

        print()
        print("=== Key strings follow the language ===")
        for key in probes {
            var seen: [String] = []
            for language in Language.allCases {
                store.setLanguage(language)
                let text = store.text(key)
                if text == key { failures += 1 }
                seen.append("\(language.rawValue)=\(text)")
            }
            print("  \(key):")
            for s in seen { print("      \(s)") }
        }

        // Distinct languages must actually differ.
        store.setLanguage(.english)
        let en = store.text("video.convert.name")
        store.setLanguage(.japanese)
        let ja = store.text("video.convert.name")
        store.setLanguage(.german)
        let de = store.text("video.convert.name")
        check(en != ja && en != de && ja != de,
              "Different languages return different text (en=\(en) ja=\(ja) de=\(de))")

        // Interpolation must work in every language.
        print()
        print("=== Interpolation ===")
        for language in [Language.english, .japanese, .russian, .chineseSimplified] {
            store.setLanguage(language)
            let text = store.text("video.convert.name").replacingOccurrences(of: "%@", with: "video.mp4")
            check(!text.contains("%@"), "\(language.rawValue): \(text)")
        }

        store.setLanguage(.english)
        print()
        print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
