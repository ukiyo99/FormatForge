import SwiftUI
import UniformTypeIdentifiers

@main
struct FormatForgeApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("FormatForge", id: "main") {
            MainWindow()
                .environment(state)
                .frame(minWidth: 1000, minHeight: 640)
                .background(Palette.windowBackground)
                .onAppear {
                    FileIO.purgeStaleScratch()
                    state.queue.maxConcurrency = state.settings.maxConcurrency
                }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands { menuCommands }

        Settings {
            SettingsView()
                .environment(state)
        }
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("ui.add_files")) { openPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button(L("ui.clear_file_list")) { state.clearInputs() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button(L("ui.start")) { state.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.canRun)
            Button(L("ui.cancel_all_tasks")) { state.queue.cancelAll() }
                .keyboardShortcut(".", modifiers: .command)
        }
        CommandMenu(L("ui.view")) {
            Button(L("ui.command_palette")) { state.showingCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button(L("ui.show_hide_task_panel")) { state.showingInspector.toggle() }
                .keyboardShortcut("j", modifiers: .command)
            Divider()
            Button(L("ui.settings")) { state.showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func openPanel() {
        let tool = state.selectedTool
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = tool.allowsMultiple
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = L("ui.choose_files")
        if !tool.accepts.isEmpty {
            panel.allowedContentTypes = tool.accepts.compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK {
            state.addInputs(panel.urls)
        }
    }
}
