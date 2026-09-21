import SwiftUI
import AppKit

// MARK: - Window shell

struct MainWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        // Reading the language registers an observation dependency: without it
        // SwiftUI has no reason to rebuild when the language changes. The .id()
        // then forces a full teardown, because tool names and labels are
        // produced by L() at construction time and cached in the registry.
        let language = state.localization.language
        return NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: Metrics.sidebarWidth, max: 280)
        } detail: {
            HStack(spacing: 0) {
                ToolWorkspace()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if state.showingInspector {
                    Divider().overlay(Palette.separator)
                    InspectorPanel()
                        .frame(width: Metrics.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Palette.contentBackground)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .overlay(alignment: .top) { ToastOverlay() }
        .sheet(isPresented: $state.showingCommandPalette) { CommandPalette() }
        .sheet(isPresented: $state.showingSettings) { SettingsView().environment(state) }
        .animation(Motion.snappy, value: state.showingInspector)
        .id(language)
    }
}

/// Lets the user drag the window by a custom header area.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Palette.separator)
            toolList
            Divider().overlay(Palette.separator)
            footer
        }
        .background(Palette.windowBackground)
        .navigationTitle("FormatForge")
    }

    private var searchField: some View {
        @Bindable var state = state
        return HStack(spacing: Metrics.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
            TextField(L("ui.search"), text: $state.searchText)
                .textFieldStyle(.plain)
                .font(Type.callout)
            if !state.searchText.isEmpty {
                IconButton(symbol: "xmark.circle.fill", size: 16) { state.searchText = "" }
            }
        }
        .padding(.horizontal, Metrics.s2)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .fill(Palette.hover)
        )
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, Metrics.s2)
    }

    private var toolList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(ToolCategory.allCases) { category in
                    let tools = state.tools(in: category)
                    if !tools.isEmpty {
                        categoryHeader(category, count: tools.count)
                        ForEach(tools) { tool in
                            ToolRow(tool: tool, selected: tool.id == state.selectedToolID)
                                .onTapGesture { state.select(tool) }
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.s2)
            .padding(.vertical, Metrics.s2)
        }
    }

    private func categoryHeader(_ category: ToolCategory, count: Int) -> some View {
        HStack(spacing: Metrics.s1) {
            Text(category.title)
                .font(Type.caption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            let staged = state.stagedCount(in: category)
            if staged > 0 {
                // A dot marks categories with files already staged, so work in
                // progress is visible without leaving the current tool.
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 5, height: 5)
                    .help(L("ui.staged_tool_s_in_this_category_have_files", staged))
            }
        }
        .padding(.horizontal, Metrics.s2)
        .padding(.top, Metrics.s3)
        .padding(.bottom, Metrics.s1)
    }

    private var footer: some View {
        HStack(spacing: Metrics.s2) {
            Circle()
                .fill(FFmpeg.available ? Palette.success : Palette.danger)
                .frame(width: 6, height: 6)
            Text(FFmpeg.available ? L("ui.ffmpeg_ready") : L("ui.ffmpeg_missing"))
                .font(Type.caption)
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
            Button {
                state.showingCommandPalette = true
            } label: {
                Text("⌘K")
                    .font(Type.mono(9, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help(L("ui.command_palette"))
        }
        .padding(.horizontal, Metrics.s3)
        .frame(height: 26)
    }
}

/// A single tool row, styled like a source-list item.
struct ToolRow: View {
    let tool: Tool
    let selected: Bool

    @Environment(AppState.self) private var state
    @State private var hovering = false

    private var staged: Int {
        state.stagedInputs(for: tool.id)
    }

    var body: some View {
        HStack(spacing: Metrics.s2) {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? .white : tool.category.accent)
                .frame(width: 18)

            // Tool names run long in several languages — the Russian OCR entry
            // is 291pt — so wrap to two lines rather than clipping. The row
            // grows to fit, which is why the height below is a minimum.
            Text(tool.name)
                .font(selected ? Type.callout.weight(.medium) : Type.callout)
                .foregroundStyle(selected ? .white : Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .help(tool.name)

            Spacer(minLength: Metrics.s1)

            // Files staged for this tool, so parallel work is discoverable.
            if staged > 0 && !selected {
                Text("\(staged)")
                    .font(Type.mono(9, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Palette.hover)
                    )
            }
        }
        .padding(.horizontal, Metrics.s2)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .fill(selected
                      ? Palette.accent
                      : (hovering ? Palette.hover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tool.summary)
    }
}

// MARK: - Toast

struct ToastOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let toast = state.toast {
                HStack(spacing: Metrics.s2) {
                    Image(systemName: toast.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(toast.color)
                    Text(toast.text)
                        .font(Type.callout)
                        .foregroundStyle(Palette.textPrimary)
                }
                .padding(.horizontal, Metrics.s4)
                .frame(height: 32)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.top, Metrics.s4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(Motion.snappy, value: state.toast)
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Tool] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.tools }
        return state.tools.filter {
            $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
                || $0.category.title.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textTertiary)
                TextField(L("ui.search_tools"), text: $query)
                    .textFieldStyle(.plain)
                    .font(Type.title)
                    .focused($focused)
                    .onSubmit(open)
            }
            .padding(.horizontal, Metrics.s4)
            .frame(height: 44)

            Divider().overlay(Palette.separator)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.prefix(40).enumerated()), id: \.element.id) { index, tool in
                            Button {
                                state.select(tool)
                                dismiss()
                            } label: {
                                HStack(spacing: Metrics.s3) {
                                    ToolIcon(symbol: tool.symbol, category: tool.category, size: 22)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(tool.name)
                                            .font(Type.callout)
                                            .foregroundStyle(Palette.textPrimary)
                                        Text(tool.summary)
                                            .font(Type.caption)
                                            .foregroundStyle(Palette.textTertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Text(tool.category.title)
                                        .font(Type.caption2)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                                .padding(.horizontal, Metrics.s3)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == highlighted ? Palette.accent.opacity(0.14) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(Metrics.s1)
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 480)
        .background(Palette.windowBackground)
        .onAppear { focused = true }
    }

    private func open() {
        if let first = results.first {
            state.select(first)
            dismiss()
        }
    }
}
