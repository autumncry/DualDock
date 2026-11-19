import SwiftUI

/// A label and its explanation share a single leading edge across setting rows.
struct SettingsOptionLabel: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsOptionRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsOptionLabel(title: title, detail: detail)
            control.fixedSize()
        }
        .frame(minHeight: 30)
    }
}

struct SettingsSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsOptionLabel(title: title, detail: detail)
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
