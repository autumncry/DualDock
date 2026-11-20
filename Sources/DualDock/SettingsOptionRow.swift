import SwiftUI

/// A label and its explanation share a single leading edge across setting rows.
struct SettingsOptionLabel: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsOptionRow<Control: View>: View {
    let title: String
    let detail: String?
    let symbol: String?
    let control: Control

    init(_ title: String, detail: String? = nil, symbol: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsOptionLabel(title: title, detail: detail, symbol: symbol)
            control.fixedSize()
        }
        .frame(minHeight: 36)
    }
}

struct SettingsSwitchRow: View {
    let title: String
    let detail: String
    var symbol: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsOptionLabel(title: title, detail: detail, symbol: symbol)
        }
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
