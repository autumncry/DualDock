import SwiftUI

/// One native button makes the chevron, title and header whitespace equally
/// clickable, while keeping keyboard activation and the expanded state explicit.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.dualDockLanguage) private var localize
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localize("高级设置", "Advanced"))
            .accessibilityValue(configuration.isExpanded ? localize("已展开", "Expanded") : localize("已收起", "Collapsed"))
            if configuration.isExpanded { configuration.content.padding(.bottom, 12) }
        }
    }
}

private struct SettingsLabelWidth: EnvironmentKey {
    static let defaultValue: CGFloat = 112
}

extension EnvironmentValues {
    var settingsLabelWidth: CGFloat {
        get { self[SettingsLabelWidth.self] }
        set { self[SettingsLabelWidth.self] = newValue }
    }
}

/// Shared three-column rhythm: labels, controls, then numeric values.
struct SettingsFormRow<Content: View>: View {
    @Environment(\.settingsLabelWidth) private var labelWidth
    let title: String
    var note: String? = nil
    let content: Content
    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.frame(width: labelWidth, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 3).frame(minHeight: 45)
    }
}

struct SettingsFormSlider: View {
    @Environment(\.dualDockLanguage) private var localize
    let title: String
    var note: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "pt"
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    @FocusState private var editingValue: Bool
    private var constrained: Binding<Double> {
        Binding(get: { value }, set: { next in
            guard next.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, next))
        })
    }
    var body: some View {
        SettingsFormRow(title, note: note) {
            HStack(spacing: 12) {
                Slider(value: constrained, in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound),
                       onEditingChanged: { onEditingChanged($0); onFocus($0) })
                    .disabled(range.lowerBound >= range.upperBound).accessibilityLabel(title)
                HStack(spacing: 5) {
                    TextField(title, value: constrained, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
                        .textFieldStyle(.roundedBorder).frame(width: 56).focused($editingValue)
                        .accessibilityLabel(localize("\(title)数值", "\(title) value")).onSubmit { onEditingChanged(false) }
                    Text(unit).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                }.frame(width: 81)
            }
        }
        .onHover { if !editingValue { onFocus($0) } }
        .onChange(of: editingValue) { _, focused in onFocus(focused); if !focused { onEditingChanged(false) } }
    }
}
