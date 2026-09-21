import Foundation
import Observation

/// Per-tool working state.
///
/// Every tool keeps its own inputs, parameters, preset and output folder, so
/// switching tools never discards work and — crucially — a long encode in one
/// tool does not block you from using another.
@Observable
@MainActor
final class ToolSession: Identifiable {
    let toolID: String

    var inputs: [URL] = []
    var parameterValues: [String: ParameterValue]
    var selectedPresetID: String
    /// Folder chosen for the next run of this tool only.
    var outputDirectory: URL?
    var estimate: WorkEstimate?
    var mediaInfo: MediaInfo?
    /// Inline results for inspection tools.
    var report: InspectionReport?
    var isInspecting = false
    /// Custom editors (GIF builder) flip this once they are ready to run.
    var customEditorReady: Bool

    nonisolated var id: String { toolID }

    /// The values this session started with, *after* the recommended preset was
    /// applied. Kept so a language switch can tell an untouched field (which
    /// should follow the new language) from one the user edited (which must be
    /// preserved).
    private(set) var defaultsAtCreation: [String: ParameterValue] = [:]

    /// Move the "untouched" baseline forward, e.g. after a language switch
    /// replaced some defaults. Without this, switching twice would compare
    /// against the first language and mistake a translated default for a value
    /// the user had edited.
    func rebaseDefaults(_ defaults: [String: ParameterValue]) {
        for (key, value) in defaults {
            defaultsAtCreation[key] = value
        }
    }

    init(tool: Tool) {
        self.toolID = tool.id
        self.parameterValues = Self.defaults(for: tool)
        self.customEditorReady = !tool.hasCustomEditor
        self.selectedPresetID = Presets.ladder(for: tool.id).first?.id ?? ""

        // Apply the recommended preset so the tool is usable immediately.
        if let preset = Presets.ladder(for: tool.id).first {
            for (key, value) in preset.values {
                parameterValues[key] = value
            }
        }

        // Snapshot the starting state; this is the baseline a language switch
        // compares against to decide what the user has changed.
        self.defaultsAtCreation = parameterValues
    }

    static func defaults(for tool: Tool) -> [String: ParameterValue] {
        var values: [String: ParameterValue] = [:]
        for parameter in tool.parameters {
            values[parameter.id] = parameter.defaultValue
        }
        return values
    }

    var tool: Tool? { ToolRegistry.tool(withID: toolID) }

    var presets: [ToolPreset] { Presets.ladder(for: toolID) }

    var selectedPreset: ToolPreset? {
        presets.first { $0.id == selectedPresetID }
    }

    /// Reset parameters to the tool defaults and re-apply a preset.
    func applyPreset(id: String) {
        guard let tool, let preset = presets.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        var values = Self.defaults(for: tool)
        for (key, value) in preset.values { values[key] = value }
        parameterValues = values
    }

    /// True when the user has edited a value away from the applied preset.
    var presetIsModified: Bool {
        guard let preset = selectedPreset, !preset.values.isEmpty else { return false }
        for (key, value) in preset.values where parameterValues[key] != value {
            return true
        }
        return false
    }

    func addInputs(_ urls: [URL]) {
        guard let tool else { return }
        let expanded = FileIO.expand(urls, accepted: tool.accepts)
        var accepted = expanded.filter { tool.acceptsURL($0) }
        if !tool.allowsMultiple { accepted = Array(accepted.prefix(1)) }

        if tool.allowsMultiple {
            let existing = Set(inputs.map(\.path))
            inputs.append(contentsOf: accepted.filter { !existing.contains($0.path) })
        } else {
            inputs = accepted
        }
    }

    func removeInput(at index: Int) {
        guard inputs.indices.contains(index) else { return }
        inputs.remove(at: index)
    }

    func moveInput(from: Int, to: Int) {
        guard inputs.indices.contains(from), inputs.indices.contains(to), from != to else { return }
        let item = inputs.remove(at: from)
        inputs.insert(item, at: to)
    }

    func clearInputs() {
        inputs.removeAll()
        estimate = nil
        mediaInfo = nil
    }

    /// Reset the transient per-run state when the tool changes underneath it.
    func pruneInputsForTool() {
        guard let tool else { return }
        inputs = inputs.filter { tool.acceptsURL($0) }
    }
}
