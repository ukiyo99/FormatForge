import SwiftUI
import AppKit
import Observation

/// Global UI state.
///
/// The important design decision: **every tool owns its own session**, and all
/// of them exist at once. Switching tools is just switching which session is
/// displayed — so a running encode in one tool never blocks another, and
/// per-tool inputs and settings survive navigation.
@Observable
@MainActor
final class AppState {
    var selectedToolID: String
    var searchText: String = ""
    var showingCommandPalette = false
    var showingSettings = false
    var showingInspector = true
    var toast: ToastMessage?

    let queue = JobQueue()
    let settings = AppSettings.shared
    /// Observable mirror of the active language; reading it in a view makes
    /// that view repaint when the language changes.
    let localization = Localization.shared

    /// One session per tool, created eagerly so state is never lost.
    @ObservationIgnored private var sessions: [String: ToolSession] = [:]
    /// Bumped whenever derived values change, to refresh the UI.
    private(set) var revision: Int = 0

    init() {
        let tools = ToolRegistry.all
        selectedToolID = tools.first?.id ?? ""
        for tool in tools {
            sessions[tool.id] = ToolSession(tool: tool)
        }
    }

    var tools: [Tool] { ToolRegistry.all }

    var selectedTool: Tool {
        ToolRegistry.tool(withID: selectedToolID) ?? tools[0]
    }

    /// The active tool's session. Always exists because sessions are eager.
    var session: ToolSession {
        if let existing = sessions[selectedToolID] { return existing }
        let created = ToolSession(tool: selectedTool)
        sessions[selectedToolID] = created
        return created
    }

    func invalidate() { revision &+= 1 }

    /// Switch language: rebuild the tool registry (its strings are captured at
    /// construction) and repaint every view.
    func setLanguage(_ language: Language) {
        guard localization.language != language else { return }
        localization.language = language

        // Tool names, option labels and hints are produced by L() when a Tool is
        // constructed, and the registry caches them — so it must be rebuilt.
        ToolRegistry.invalidate()

        // A few parameters have a *translated default value* — the rename
        // pattern, the archive name, the PDF title. Those sit in the session's
        // value dictionary, so they would keep the old language.
        //
        // Start from what the session already holds (so every edit is kept) and
        // only replace a text field whose current value still equals the value
        // it was created with, i.e. one the user has not touched.
        let rebuilt = ToolRegistry.all
        for (id, session) in sessions {
            guard let tool = rebuilt.first(where: { $0.id == id }) else { continue }
            var updated = session.parameterValues
            let fresh = ToolSession.defaults(for: tool)
            var rebased: [String: ParameterValue] = [:]
            for parameter in tool.parameters {
                guard case .text = parameter.kind else { continue }
                let createdWith = session.defaultsAtCreation[parameter.id]?.stringValue
                let current = session.parameterValues[parameter.id]?.stringValue
                if current == createdWith, let replacement = fresh[parameter.id] {
                    updated[parameter.id] = replacement
                    rebased[parameter.id] = replacement
                }
            }
            session.parameterValues = updated
            // Keep the baseline in step, so switching language twice does not
            // mistake the first translation for a user edit.
            session.rebaseDefaults(rebased)
            // Anything derived from the old strings is no longer valid.
            session.estimate = nil
            session.report = nil
        }

        invalidate()
        refreshEstimate()
        runInspectionIfNeeded()
    }

    /// How many files are staged for a given tool, used by the sidebar badges.
    func stagedInputs(for toolID: String) -> Int {
        sessions[toolID]?.inputs.count ?? 0
    }

    // MARK: - Browsing

    var filteredTools: [Tool] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return tools }
        return tools.filter {
            $0.name.lowercased().contains(query)
                || $0.summary.lowercased().contains(query)
                || $0.category.title.contains(query)
                || $0.accepts.contains(where: { $0.contains(query) })
        }
    }

    func tools(in category: ToolCategory) -> [Tool] {
        filteredTools.filter { $0.category == category }
    }

    /// Tools in this category that already have files staged.
    func stagedCount(in category: ToolCategory) -> Int {
        sessions.values.filter { session in
            guard let tool = session.tool, tool.category == category else { return false }
            return !session.inputs.isEmpty
        }.count
    }

    // MARK: - Selection

    func select(_ tool: Tool) {
        guard tool.id != selectedToolID else { return }
        selectedToolID = tool.id
        session.pruneInputsForTool()
        session.estimate = nil
        session.mediaInfo = nil
        refreshEstimate()
        runInspectionIfNeeded()
    }

    // MARK: - Presets (delegating to the active session)

    var currentPresets: [ToolPreset] { session.presets }
    var selectedPreset: ToolPreset? { session.selectedPreset }
    var selectedPresetID: String { session.selectedPresetID }
    var presetIsModified: Bool { session.presetIsModified }

    func applyPreset(id: String) {
        session.applyPreset(id: id)
        refreshEstimate()
    }

    func parametersChanged() {
        refreshEstimate()
        runInspectionIfNeeded()
    }

    // MARK: - Inspection

    /// Inspection tools compute automatically: any change to the inputs or the
    /// options recomputes the report. No button, no queue, no output folder.
    func runInspectionIfNeeded() {
        let active = session
        guard let tool = active.tool, let inspector = tool.inspector else { return }

        let inputs = active.inputs
        let values = active.parameterValues

        guard !inputs.isEmpty else {
            active.report = nil
            active.isInspecting = false
            invalidate()
            return
        }

        active.isInspecting = true
        let toolID = active.toolID

        Task { [weak self] in
            let report = await inspector.inspect(inputs: inputs, values: values) { _ in }
            guard let self else { return }
            // Discard stale results if the inputs changed while computing.
            guard let target = self.sessions[toolID], target.inputs == inputs else { return }
            target.report = report
            target.isInspecting = false
            self.invalidate()
        }
    }

    // MARK: - Inputs (delegating to the active session)

    var inputs: [URL] { session.inputs }

    func addInputs(_ urls: [URL]) {
        let before = session.inputs.count
        session.addInputs(urls)
        if session.inputs.count == before, !urls.isEmpty {
            showToast(L("ui.ignored_files_this_tool_does_not_accept"), kind: .warning)
        }
        refreshEstimate()
        runInspectionIfNeeded()
    }

    func removeInput(at index: Int) {
        session.removeInput(at: index)
        refreshEstimate()
        runInspectionIfNeeded()
    }

    func moveInput(from: Int, to: Int) {
        session.moveInput(from: from, to: to)
        invalidate()
    }

    func clearInputs() {
        session.clearInputs()
        session.report = nil
        invalidate()
    }

    func reorderInputs(_ newOrder: [URL]) {
        session.inputs = newOrder
        invalidate()
    }

    // MARK: - Parameter access

    var parameterValues: [String: ParameterValue] {
        get { session.parameterValues }
        set { session.parameterValues = newValue }
    }

    var estimate: WorkEstimate? { session.estimate }
    var mediaInfo: MediaInfo? { session.mediaInfo }
    var report: InspectionReport? { session.report }
    var isInspecting: Bool { session.isInspecting }
    /// True when the current tool computes automatically rather than on demand.
    var isInspectionTool: Bool { selectedTool.isInspection }
    var customEditorReady: Bool {
        get { session.customEditorReady }
        set { session.customEditorReady = newValue }
    }

    var outputDirectory: URL? {
        get { session.outputDirectory }
        set { session.outputDirectory = newValue }
    }

    // MARK: - Estimation

    func refreshEstimate() {
        let active = session
        let toolID = active.toolID
        let values = active.parameterValues
        let inputs = active.inputs
        let settings = self.settings

        guard !inputs.isEmpty else {
            active.estimate = nil
            active.mediaInfo = nil
            invalidate()
            return
        }

        Task { [weak self] in
            let result = await EstimateEngine.compute(
                toolID: toolID, inputs: inputs, values: values, settings: settings)
            guard let self else { return }
            // Ignore results for a session whose inputs have since changed.
            guard let target = self.sessions[toolID], target.inputs == inputs else { return }
            target.estimate = result.estimate
            target.mediaInfo = result.mediaInfo
            self.invalidate()
        }
    }

    // MARK: - Output location

    var resolvedOutputDirectory: URL {
        settings.resolveOutputDirectory(
            input: session.inputs.first ?? FileManager.default.homeDirectoryForCurrentUser,
            explicit: session.outputDirectory)
    }

    var outputSummary: String {
        if session.outputDirectory != nil { return L("ui.chosen_for_this_run") }
        switch settings.outputMode {
        case .alongsideInput: return L("ui.next_to_originals")
        case .customFolder:
            return settings.needsFolderSelection
                ? L("ui.no_folder_chosen_files_go_next_to_the_orig")
                : (settings.customOutputURL?.lastPathComponent ?? L("ui.chosen_folder"))
        case .askEveryTime: return L("ui.ask_every_time")
        }
    }

    // MARK: - Running

    var canRun: Bool {
        missingDependency == nil
            && session.inputs.count >= selectedTool.minimumInputs
            && session.customEditorReady
    }

    var missingDependency: String? {
        let tool = selectedTool
        if tool.requiresFFmpeg && !FFmpeg.available {
            return L("ui.ffmpeg_is_not_available_install_it_with_br")
        }
        if tool.requiresSevenZip && !ProcessRunner.exists("7z") {
            return L("ui.this_feature_needs_7_zip_install_it_with_b")
        }
        let selectsWebP = ["codec", "format"].contains { key in
            session.parameterValues[key]?.stringValue == "webp"
        }
        if selectsWebP && !WebPEncoder.isAvailable {
            return WebPEncoder.unavailableReason
        }
        return nil
    }

    private var needsOutputPrompt: Bool {
        // Inspection and dry-run modes never write to a chosen folder, so
        // asking for one would be pointless.
        guard writesFiles else { return false }
        return session.outputDirectory == nil && settings.outputMode == .askEveryTime
    }

    /// The primary button's label for the current tool and mode.
    var primaryActionTitle: String {
        selectedTool.primaryAction(values: session.parameterValues)
    }

    /// Whether the current tool + mode writes files.
    var writesFiles: Bool {
        selectedTool.writesFiles(values: session.parameterValues)
    }

    /// Queue the active tool's work. Prompts for a folder when configured to.
    func run() {
        guard canRun else { return }
        if needsOutputPrompt {
            guard let chosen = Self.promptForFolder(
                message: L("ui.choose_output_folder"), prompt: L("ui.start")) else {
                showToast(L("ui.cancelled_no_output_folder_chosen"), kind: .warning)
                return
            }
            session.outputDirectory = chosen
        }
        startJob()
    }

    /// Queue without prompting, using the currently resolved folder.
    func runWithoutPrompt() {
        guard canRun else { return }
        startJob()
    }

    private func startJob() {
        let tool = selectedTool
        let active = session
        let directory = resolvedOutputDirectory

        let context = ToolContext(
            toolID: tool.id,
            inputs: active.inputs,
            outputDirectory: directory,
            values: active.parameterValues,
            settings: settings,
            progress: .silent,
            handle: ProcessHandle(),
            logger: .silent
        )
        queue.enqueue(tool: tool, context: context, estimate: active.estimate)
        showToast(L("ui.queued_tool_name", tool.name), kind: .info)
    }

    static func promptForFolder(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Toast

    func showToast(_ text: String, kind: ToastMessage.Kind = .info) {
        let message = ToastMessage(text: text, kind: kind)
        withAnimation(Motion.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 5 : 2.6))
            if toast?.id == message.id {
                withAnimation(Motion.smooth) { toast = nil }
            }
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }

    let id = UUID()
    let text: String
    let kind: Kind

    var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch kind {
        case .info: return Palette.accent
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }
}
