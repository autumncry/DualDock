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
            Group {
                if kind == .systemStatus {
                    SystemStatusFace(metrics: metrics, span: span, horizontal: horizontal)
                } else {
                    axis {
                        Image(systemName: kind == .focusTimer && metrics.focusEndsAt != nil ? "pause.fill" : kind.symbol)
                            .font(.system(size: compact ? 13 : 16, weight: .medium))
                            .foregroundStyle(kind == .focusTimer ? Color.accentColor : .green)
                        VStack(alignment: horizontal && !compact ? .leading : .center, spacing: 1) {
                            Text(reading).font(.system(size: compact ? 10 : 12, weight: .semibold)).monospacedDigit()
                            if !compact { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }.lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(kind.label + " · " + reading + " · " + subtitle)
        .help(kind == .systemStatus
              ? language("查看 CPU、内存与交换空间", "View CPU, memory and swap usage")
              : kind.label + " · " + reading + " · " + subtitle)
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
        if kind == .systemStatus {
            SystemStatusDetail(cpu: metrics.cpuPercent, resources: metrics.systemResources)
        } else { otherDetail }
    }

    private var otherDetail: some View {
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

struct SystemStatusFace: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var metrics: LocalToolMetrics
    let span: Int
    let horizontal: Bool

    var body: some View {
        let axis = horizontal && span > 1 ? AnyLayout(HStackLayout(spacing: 5)) : AnyLayout(VStackLayout(spacing: 1))
        let cpu = metrics.cpuPercent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
        axis {
            Image(systemName: ShelfLayout.Kind.systemStatus.symbol)
                .font(.system(size: span == 1 ? 13 : 16, weight: .medium))
                .foregroundStyle(.green)
            ViewThatFits(in: .horizontal) {
                if horizontal && span >= 3 {
                    if span == 4 {
                        HStack(spacing: 7) {
                            faceValue(cpu, subtitle: "CPU")
                            faceValue(percent(metrics.systemResources?.memory), subtitle: language("内存", "RAM"))
                            faceValue(percent(metrics.systemResources?.swap), subtitle: "Swap")
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(spacing: 7) {
                        faceValue(cpu, subtitle: "CPU")
                        faceValue(percent(metrics.systemResources?.memory), subtitle: language("内存", "RAM"))
                    }.fixedSize(horizontal: true, vertical: false)
                }
                faceValue(cpu, subtitle: language("CPU 使用率", "CPU usage"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func faceValue(_ reading: String, subtitle: String) -> some View {
        VStack(alignment: horizontal && span > 1 ? .leading : .center, spacing: 1) {
            Text(reading).font(.system(size: span == 1 ? 10 : 12, weight: .semibold)).monospacedDigit()
            if span > 1 { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.lineLimit(1).minimumScaleFactor(0.8)
    }

    private func percent(_ usage: SystemByteUsage?) -> String {
        guard let usage, usage.total > 0 else { return "—" }
        return (Double(usage.used) / Double(usage.total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

struct SystemStatusDetail: View {
    @Environment(\.dualDockLanguage) private var language
    let cpu: Double?
    let resources: SystemResourceSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language("系统状态", "System Status")).font(.headline)
            row(language("CPU 使用率", "CPU usage"),
                value: cpu.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) }
                    ?? language("采样中…", "Sampling…"),
                fraction: cpu.map { $0 / 100 })
            usageRow(language("已用内存", "Memory used"), usage: resources?.memory)
                .help(language("包含驻留的匿名内存、系统常驻内存和压缩内容实际占用的内存。", "Includes resident anonymous memory, wired memory and the physical size of compressed data."))
            usageRow(language("已用交换空间", "Swap used"), usage: resources?.swap)
                .help(language("当前交换用量与 macOS 已分配的交换空间。", "Current swap usage and the swap space allocated by macOS."))
        }
        .font(.system(size: 13))
        .frame(width: 242, alignment: .leading)
        .padding(14)
        .accessibilityIdentifier("DualDock3.SystemStatus.Detail")
    }

    private func usageRow(_ label: String, usage: SystemByteUsage?) -> some View {
        let value: String
        if let usage, usage.total > 0 {
            let format = ByteCountFormatStyle(style: .memory, spellsOutZero: false)
                .locale(Locale(identifier: language.rawValue))
            value = format.format(Int64(usage.used)) + " / " + format.format(Int64(usage.total))
        } else if usage != nil {
            value = language("尚未分配", "Not allocated")
        } else {
            value = resources == nil ? language("读取中…", "Loading…") : language("暂不可用", "Unavailable")
        }
        let fraction = usage.flatMap { $0.total > 0 ? Double($0.used) / Double($0.total) : nil }
        return row(label, value: value, fraction: fraction)
    }

    private func row(_ title: String, value: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).monospacedDigit().foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear).tint(.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
