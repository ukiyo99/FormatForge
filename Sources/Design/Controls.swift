import SwiftUI

// MARK: - Field row

/// Label + control, laid out the way macOS settings panes do it: the label
/// leads, the control trails, and the hint sits underneath in caption grey.
struct FieldRow<Control: View>: View {
    let label: String
    var hint: String? = nil
    var inline: Bool = false
    @ViewBuilder var control: Control

    var body: some View {
        if inline {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.s3) {
                // German and Portuguese labels are often twice the length of
                // the English source, so the label must wrap rather than push
                // the control off the edge.
                Text(label)
                    .font(Type.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: Metrics.s2)
                control
                    .layoutPriority(2)
            }
            .frame(minHeight: Metrics.controlHeight)
        } else {
            VStack(alignment: .leading, spacing: Metrics.s1) {
                Text(label)
                    .font(Type.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                control
                if let hint {
                    Text(hint)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Text field

struct LabeledTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? Type.mono(12) : Type.body)
            .controlSize(.regular)
    }
}

// MARK: - Number field

/// Numeric entry backed by a native stepper, clamped to the allowed range.
struct NumberInput: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Metrics.s2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Type.mono(12))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }

            Stepper("") {
                value = clamp(value + step)
                text = render(value)
            } onDecrement: {
                value = clamp(value - step)
                text = render(value)
            }
            .labelsHidden()
        }
        .onAppear { text = render(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = render(newValue) }
        }
    }

    private func commit() {
        value = clamp(Double(text.trimmingCharacters(in: .whitespaces)) ?? value)
        text = render(value)
    }

    private func clamp(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    private func render(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

// MARK: - Slider

/// Native slider with a live numeric readout.
struct SliderInput: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var display: (Double) -> String

    var body: some View {
        HStack(spacing: Metrics.s3) {
            Slider(value: $value, in: range, step: step)
            Text(display(value))
                .font(Type.mono(11.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

// MARK: - Toggle

struct SwitchToggle: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.accent

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(tint)
            .controlSize(.small)
    }
}

// MARK: - Pickers

/// Segmented picker for short option sets.
struct SegmentPicker: View {
    let options: [PickerOption]
    @Binding var selection: String

    private var segmented: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
    }

    var body: some View {
        // A segmented control cannot shrink or wrap, so a long translation —
        // Spanish "Preguntar cada vez" against English "Ask" — would be clipped
        // at the edge of its pane. ViewThatFits tries the segmented control
        // first and falls back to a menu when the labels do not fit, without
        // consuming more width than it is given (which a GeometryReader would).
        ViewThatFits(in: .horizontal) {
            segmented
            PopUpPicker(options: options, selection: $selection)
        }
    }
}

/// Pop-up picker for longer option sets, with the detail text as a tooltip.
struct PopUpPicker: View {
    let options: [PickerOption]
    @Binding var selection: String

    private var current: PickerOption? {
        options.first { $0.id == selection }
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.regular)
        // The menu shows the selected option, whose name can be long in some
        // languages; let it truncate rather than widen the whole row.
        .lineLimit(1)
        .truncationMode(.tail)
        .help(current?.detail ?? current?.label ?? "")
    }
}

// MARK: - Parameter form

/// Renders a tool's parameter list, honouring conditional visibility.
/// Controls are native macOS controls so the form feels like the rest of the OS.
struct ParameterForm: View {
    let parameters: [ToolParameter]
    @Binding var values: [String: ParameterValue]
    var accent: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s4) {
            ForEach(visible) { parameter in
                row(for: parameter)
            }
        }
    }

    private var visible: [ToolParameter] {
        parameters.filter { $0.visibleWhen.isVisible(in: values) }
    }

    @ViewBuilder
    private func row(for parameter: ToolParameter) -> some View {
        switch parameter.kind {
        case .text(let placeholder):
            FieldRow(label: parameter.label, hint: parameter.hint) {
                LabeledTextField(placeholder: placeholder, text: stringBinding(parameter.id))
            }

        case .number(let min, let max, let step):
            FieldRow(label: parameter.label, hint: parameter.hint) {
                NumberInput(value: numberBinding(parameter.id), range: min...max, step: step)
            }

        case .slider(let min, let max, let step):
            FieldRow(label: parameter.label, hint: parameter.hint) {
                SliderInput(
                    value: numberBinding(parameter.id),
                    range: min...max,
                    step: step,
                    display: { value in
                        value == value.rounded()
                            ? String(Int(value))
                            : String(format: "%.1f", value)
                    }
                )
            }

        case .toggle:
            FieldRow(label: parameter.label, hint: parameter.hint, inline: true) {
                SwitchToggle(isOn: boolBinding(parameter.id), tint: accent)
            }

        case .picker(let options):
            // Short option sets read better as segments; longer ones as menus.
            if options.count <= 4 && options.allSatisfy({ $0.label.count <= 7 }) {
                FieldRow(label: parameter.label, hint: parameter.hint) {
                    SegmentPicker(options: options, selection: stringBinding(parameter.id))
                }
            } else {
                FieldRow(label: parameter.label, hint: parameter.hint) {
                    PopUpPicker(options: options, selection: stringBinding(parameter.id))
                }
            }
        }
    }

    // MARK: bindings

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key]?.stringValue ?? "" },
            set: { values[key] = .text($0) }
        )
    }

    private func numberBinding(_ key: String) -> Binding<Double> {
        Binding(
            get: { values[key]?.doubleValue ?? 0 },
            set: { values[key] = .number($0) }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { values[key]?.boolValue ?? false },
            set: { values[key] = .bool($0) }
        )
    }
}
