import SwiftUI

/// Shared three-column rhythm: labels, controls, then numeric values.
struct SettingsFormRow<Content: View>: View {
    let title: String
    var note: String? = nil
    let content: Content
    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(width: 108, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 54)
    }
}

struct SettingsFormSlider: View {
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
            HStack(spacing: 22) {
                Slider(value: constrained, in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound),
                       onEditingChanged: { onEditingChanged($0); onFocus($0) })
                    .disabled(range.lowerBound >= range.upperBound).accessibilityLabel(title)
                HStack(spacing: 5) {
                    TextField(title, value: constrained, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
                        .textFieldStyle(.roundedBorder).frame(width: 56).focused($editingValue)
                        .accessibilityLabel("\(title)数值").onSubmit { onEditingChanged(false) }
                    Text(unit).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                }.frame(width: 81)
            }
        }
        .onHover { if !editingValue { onFocus($0) } }
        .onChange(of: editingValue) { _, focused in onFocus(focused); if !focused { onEditingChanged(false) } }
    }
}
