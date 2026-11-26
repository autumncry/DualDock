import SwiftUI
import DualDockCore

struct LocalToolCardView: View {
    @Environment(\.dualDockLanguage) private var language
    let kind: ShelfLayout.Kind
    @ObservedObject var metrics: LocalToolMetrics
    let span: Int
    let horizontal: Bool
    let visible: Bool
    let onDetailChange: (Bool) -> Void
    @State private var detailOpen = false

    var body: some View {
        Group {
            if kind == .focusTimer, visible, metrics.focusEndsAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in control(at: context.date) }
            } else {
                control(at: .now)
            }
        }
        .popover(isPresented: $detailOpen) { detail }
        .onChange(of: detailOpen) { _, value in onDetailChange(value) }
        .onDisappear { onDetailChange(false) }
        .contextMenu {
            Button(language("查看详情", "Show Details")) { detailOpen = true }
        }
    }

    private func control(at date: Date) -> some View {
        let reading = value(at: date)
        let compact = span == 1
        let axis = horizontal && !compact ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(spacing: 1))
        return Button {
            if kind == .focusTimer { metrics.toggleFocus() }
            else { detailOpen = true }
        } label: {
            axis {
                Image(systemName: kind == .focusTimer && metrics.focusEndsAt != nil ? "pause.fill" : kind.symbol)
                    .font(.system(size: compact ? 13 : 16, weight: .medium))
                    .foregroundStyle(kind == .focusTimer ? Color.accentColor : .green)
                VStack(alignment: horizontal && !compact ? .leading : .center, spacing: 1) {
                    Text(reading).font(.system(size: compact ? 10 : 12, weight: .semibold)).monospacedDigit()
                    if !compact {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(kind.label + " · " + reading + " · " + subtitle)
        .help(kind.label + " · " + reading + " · " + subtitle)
    }

    private var subtitle: String {
        switch kind {
        case .systemStatus: return language("CPU 使用率", "CPU usage")
        case .battery: return language("电池电量", "Battery charge")
        case .storage: return language("可用磁盘", "Available storage")
        case .focusTimer:
            return metrics.focusEndsAt != nil ? language("专注中", "Focusing") : language("开始或继续", "Start or resume")
        default: return ""
        }
    }

    private func value(at date: Date) -> String {
        switch kind {
        case .systemStatus:
            return metrics.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—"
        case .battery:
            return metrics.batteryPercent.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—"
        case .storage:
            return metrics.diskAvailableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case .focusTimer:
            let remaining = metrics.focusEndsAt?.timeIntervalSince(date) ?? metrics.focusRemaining
            let total = max(0, Int(ceil(remaining)))
            return String(format: "%d:%02d", total / 60, total % 60)
        default: return "—"
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.label).font(.headline)
            if kind == .focusTimer {
                Picker(language("时长", "Duration"), selection: Binding(
                    get: { Int(metrics.focusDuration / 60) },
                    set: { metrics.setFocusDuration(minutes: $0) })) {
                    ForEach([5, 15, 25, 45, 60], id: \.self) { n in Text(language("\(n) 分钟", "\(n) minutes")).tag(n) }
                }
                HStack {
                    Button(metrics.focusEndsAt == nil ? language("开始或继续", "Start or Resume") : language("暂停", "Pause")) {
                        metrics.toggleFocus()
                    }
                    Button(language("重置", "Reset")) { metrics.resetFocus() }
                }
            } else {
                LabeledContent(subtitle, value: value(at: .now))
                if kind == .storage, let capacity = metrics.diskTotalBytes {
                    LabeledContent(language("磁盘容量", "Capacity"),
                                   value: ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file))
                }
                if kind == .battery && metrics.batteryPercent == nil {
                    Text(language("未检测到电池", "No battery detected")).foregroundStyle(.secondary)
                }
            }
        }.font(.system(size: 13)).frame(width: 220, alignment: .leading).padding(14)
    }
}
