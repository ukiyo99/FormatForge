import Foundation

// Emits the live tool registry as JSON so the tutorial generator never has to
// parse Swift source to learn what each tool does.
//
// Every translatable string is emitted once per language: the tutorial shows all
// of them at the same time and switches in the browser, so a single-language
// dump would leave the tool cards in whichever language the build happened to
// run in.
@main struct Dump {
    /// Languages the app ships, matching the Language enum.
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr",
                            "de", "es", "pt", "ru", "it", "nl"]

    /// Run `body` with each language active, collecting one result per language.
    static func perLanguage(_ body: () -> Any) -> [String: Any] {
        var out: [String: Any] = [:]
        for code in languages {
            if let language = Language(rawValue: code) {
                LanguageStore.shared.setLanguage(language)
                ToolRegistry.invalidate()
            }
            out[code] = body()
        }
        // Leave the process in English so anything after this is predictable.
        LanguageStore.shared.setLanguage(.english)
        ToolRegistry.invalidate()
        return out
    }

    /// One string per language.
    static func translated(_ value: (Tool) -> String, _ tool: Tool) -> [String: String] {
        var out: [String: String] = [:]
        for code in languages {
            if let language = Language(rawValue: code) {
                LanguageStore.shared.setLanguage(language)
                ToolRegistry.invalidate()
            }
            out[code] = value(ToolRegistry.tool(withID: tool.id) ?? tool)
        }
        LanguageStore.shared.setLanguage(.english)
        ToolRegistry.invalidate()
        return out
    }

    static func main() {
        var tools: [[String: Any]] = []

        for tool in ToolRegistry.all {
            // Parameter labels and hints, per language.
            var parameters: [[String: Any]] = []
            for p in tool.parameters {
                var kind: String
                var extra: [String: Any] = [:]
                switch p.kind {
                case .text(let placeholder):
                    kind = "text"; extra["placeholder"] = placeholder
                case .number(let min, let max, let step):
                    kind = "number"; extra["min"] = min; extra["max"] = max; extra["step"] = step
                case .slider(let min, let max, let step):
                    kind = "slider"; extra["min"] = min; extra["max"] = max; extra["step"] = step
                case .toggle:
                    kind = "toggle"
                case .picker(let options):
                    kind = "picker"
                    extra["options"] = options.map { ["id": $0.id, "label": $0.label, "detail": $0.detail ?? ""] }
                }
                parameters.append([
                    "id": p.id,
                    "label": translated({ $0.parameters.first { $0.id == p.id }?.label ?? p.label }, tool),
                    "hint": translated({ $0.parameters.first { $0.id == p.id }?.hint ?? "" }, tool),
                    "kind": kind, "default": p.defaultValue.stringValue,
                    "extra": extra,
                ])
            }

            // Presets, per language.
            let presetIDs = Presets.ladder(for: tool.id).map { $0.id }
            var presets: [[String: Any]] = []
            for presetID in presetIDs {
                let base = Presets.ladder(for: tool.id).first { $0.id == presetID }
                presets.append([
                    "id": presetID,
                    "label": translated({ _ in
                        Presets.ladder(for: tool.id).first { $0.id == presetID }?.label ?? ""
                    }, tool),
                    "detail": translated({ _ in
                        Presets.ladder(for: tool.id).first { $0.id == presetID }?.detail ?? ""
                    }, tool),
                    "symbol": base?.symbol ?? "",
                    "values": (base?.values ?? [:]).mapValues { $0.stringValue },
                ])
            }

            tools.append([
                "id": tool.id,
                "name": translated({ $0.name }, tool),
                "summary": translated({ $0.summary }, tool),
                "symbol": tool.symbol,
                "category": tool.category.rawValue,
                "categoryTitle": translated({ $0.category.title }, tool),
                "accepts": tool.accepts,
                "allowsMultiple": tool.allowsMultiple,
                "requiresFFmpeg": tool.requiresFFmpeg,
                "requiresSevenZip": tool.requiresSevenZip,
                "resultKind": tool.resultKind.rawValue,
                "actionTitle": translated({ $0.actionTitle ?? "" }, tool),
                "isInspection": tool.isInspection,
                "minimumInputs": tool.minimumInputs,
                "hasCustomEditor": tool.hasCustomEditor,
                "parameters": parameters,
                "presets": tool.isInspection ? [] : presets,
            ])
        }

        // Category titles, per language.
        var categories: [[String: Any]] = []
        for category in ToolCategory.allCases {
            var titles: [String: String] = [:]
            for code in languages {
                if let language = Language(rawValue: code) {
                    LanguageStore.shared.setLanguage(language)
                    ToolRegistry.invalidate()
                }
                titles[code] = ToolCategory(rawValue: category.rawValue)?.title ?? category.title
            }
            LanguageStore.shared.setLanguage(.english)
            ToolRegistry.invalidate()
            categories.append(["id": category.rawValue, "title": titles])
        }

        let root: [String: Any] = [
            "toolCount": ToolRegistry.all.count,
            "languages": languages,
            "categories": categories,
            "tools": tools,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root,
                                               options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
