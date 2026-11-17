import AppKit
import SwiftUI
import DualDockCore

enum DockPreviewFocus: Equatable { case none, size, density, length, height }

/// A proportional rendering of the production geometry, not a second size model.
struct SettingsDockPreview: View {
    @ObservedObject var store: AppStore
    let displayID: String?
    var focus: DockPreviewFocus = .none
    var compact = false

    private var display: DockDisplayInfo? { store.displays.first { $0.id == displayID } }
    private var presentation: DockPresentation { store.presentation(for: displayID) }
    private var entries: [DockEntry] { store.displayedEntries }
    private var geometry: DockGeometry {
        var style = presentation.style
        style.magnificationScale = 1
        return .make(count: entries.count, edge: presentation.edge, style: style,
                     maximumLength: presentation.maximumLength, fixedLength: presentation.fixedLength,
                     dividerIndex: store.pinnedCount > 0 && store.pinnedCount < entries.count ? store.pinnedCount : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(display?.name ?? "Dock 预览", systemImage: "display")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text("实时预览").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let area = proxy.size
                let g = geometry
                let scale = max(0.01, min(1, min((area.width - 32) / max(1, g.canvasSize.width),
                                                (area.height - 36) / max(1, g.canvasSize.height))))
                let width = g.canvasSize.width * scale
                let height = g.canvasSize.height * scale
                let origin = origin(size: CGSize(width: width, height: height), area: area, edge: presentation.edge)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                    if scale < 0.65 && focus != .length && !entries.isEmpty {
                        let detail = detailGeometry(maximumLength: area.width - (presentation.edge.isHorizontal ? 36 : 100))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("局部细节").font(.system(size: 10)).foregroundStyle(.secondary)
                            dockDrawing(detail, scale: 1)
                                .frame(width: detail.canvasSize.width, height: detail.canvasSize.height)
                        }
                        .offset(x: presentation.edge == .left ? width + 30 : 18,
                                y: presentation.edge == .top ? max(18, area.height - detail.canvasSize.height - 38) : 18)
                    }
                    dockDrawing(g, scale: scale)
                        .frame(width: width, height: height)
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .frame(height: compact ? 158 : 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(edgeTitle(presentation.edge)) Dock 预览，高度 \(dockPoints(geometry.barThickness))，长度 \(dockPoints(geometry.bodyLength))，\(entries.count) 个应用或分组")
            HStack(spacing: 16) {
                metric("图标", value: dockPoints(presentation.style.iconSize), active: focus == .size)
                metric("高度", value: dockPoints(geometry.barThickness), active: focus == .height)
                metric("长度", value: dockPoints(geometry.bodyLength), active: focus == .length)
                metric("间距", value: dockPoints(presentation.style.gap), active: focus == .density)
                Spacer(minLength: 0)
            }
        }
    }

    private func detailGeometry(maximumLength: CGFloat) -> DockGeometry {
        var style = presentation.style
        style.magnificationScale = 1
        return .make(count: min(3, entries.count), edge: .bottom, style: style,
                     maximumLength: max(1, maximumLength))
    }

    private func metric(_ label: String, value: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
    }

    private func dockDrawing(_ g: DockGeometry, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            let bar = screenRect(g.backdropRect, canvasHeight: g.canvasSize.height, scale: scale)
            RoundedRectangle(cornerRadius: min(14, g.barThickness * scale * 0.28))
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: min(14, g.barThickness * scale * 0.28))
                    .strokeBorder(focus == .height || focus == .length ? Color.accentColor : Color.primary.opacity(0.13),
                                  lineWidth: focus == .height || focus == .length ? 1.5 : 0.5))
                .frame(width: bar.width, height: bar.height).offset(x: bar.minX, y: bar.minY)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if g.iconFrames.indices.contains(index) {
                    let scroll = g.scrollOrigin(forCanonicalOffset: 0)
                    let raw = g.iconFrames[index].offsetBy(dx: g.viewportRect.minX - scroll.x, dy: g.viewportRect.minY - scroll.y)
                    let rect = screenRect(raw, canvasHeight: g.canvasSize.height, scale: scale)
                    Group {
                        if entry.isGroup {
                            Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(Color.accentColor)
                                .overlay(HStack(spacing: 0) {
                                    ForEach(Array(entry.apps.prefix(2)), id: \.id) { app in
                                        Image(nsImage: store.icon(for: app)).resizable().scaledToFit()
                                    }
                                }.padding(rect.width * 0.18).offset(y: rect.height * 0.1))
                        } else if let app = entry.apps.first {
                            Image(nsImage: store.icon(for: app)).resizable().scaledToFit()
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .overlay(RoundedRectangle(cornerRadius: rect.width * 0.22)
                        .stroke(focus == .size ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func screenRect(_ rect: CGRect, canvasHeight: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: (canvasHeight - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
    private func origin(size: CGSize, area: CGSize, edge: DockEdge) -> CGPoint {
        switch edge {
        case .bottom: return CGPoint(x: (area.width - size.width) / 2, y: area.height - size.height - 14)
        case .top: return CGPoint(x: (area.width - size.width) / 2, y: 14)
        case .left: return CGPoint(x: 14, y: (area.height - size.height) / 2)
        case .right: return CGPoint(x: area.width - size.width - 14, y: (area.height - size.height) / 2)
        }
    }
}

func edgeTitle(_ edge: DockEdge) -> String {
    switch edge { case .bottom: return "底部"; case .left: return "左侧"; case .right: return "右侧"; case .top: return "顶部" }
}

struct SettingsNumericSlider: View {
    let title: String
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 10)
                TextField(title, value: constrained, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
                    .textFieldStyle(.roundedBorder).frame(width: 60).focused($editingValue)
                    .accessibilityLabel("\(title)数值")
                    .onSubmit { onEditingChanged(false) }
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .leading)
            }
            Slider(value: constrained, in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound),
                   onEditingChanged: { onEditingChanged($0); onFocus($0) })
                .disabled(range.lowerBound >= range.upperBound).accessibilityLabel(title)
        }
        .onHover { if !editingValue { onFocus($0) } }
        .onChange(of: editingValue) { _, focused in onFocus(focused); if !focused { onEditingChanged(false) } }
    }
}
