import AppKit
import SwiftUI
import DualDockCore

enum DockPreviewFocus: Equatable { case none, size, density, length, height }

/// Uses production geometry at the user's explicit preview zoom.
struct SettingsDockPreview: View {
    @ObservedObject var store: AppStore
    let displayID: String?
    var focus: DockPreviewFocus = .none
    var compact = false
    @State private var zoom = 0.75

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
        let g = geometry
        let actualIcon = g.canonicalIconFrames.first?.width ?? presentation.style.iconSize
        let requestedIcon = store.customSizing(for: displayID).iconSize
        let adjusted = !store.configuration.adaptiveSizing && abs(actualIcon - requestedIcon) > 0.1
        VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Dock 预览").font(.system(size: 12, weight: .medium))
                    Text(display?.name ?? edgeTitle(presentation.edge))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("缩放").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("预览缩放", selection: $zoom) {
                        Text("50%").tag(0.5)
                        Text("75%").tag(0.75)
                        Text("100%").tag(1.0)
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 68)
                    .help("固定缩放比例，调整 Dock 尺寸时保持不变")
                }
                .padding(.horizontal, 15).frame(height: 38)
                SettingsPreviewCanvas(geometry: g, zoom: zoom, focus: focus,
                    images: entries.map { entry in
                        SettingsPreviewImages(isGroup: entry.isGroup,
                            images: entry.apps.prefix(entry.isGroup ? 3 : 1).map { store.icon(for: $0) })
                    })
                    .frame(height: 152)
                    .overlay {
                        GeometryReader { proxy in
                            let layout = SettingsPreviewLayout(geometry: g, zoom: zoom, viewportSize: proxy.size)
                            if layout.maximumScrollOffset.x > 0 {
                                Text(g.edge.isHorizontal ? "左右滚动查看完整 Dock" : "上下滚动查看完整 Dock")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: g.edge == .top ? .bottom : .top)
                                    .padding(.vertical, 6)
                            }
                        }.allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(edgeTitle(presentation.edge)) Dock，实际图标 \(dockPoints(actualIcon))，高度 \(dockPoints(g.barThickness))，\(entries.count) 个应用或分组，预览缩放 \(Int(zoom * 100))%")
                    .help("滚动查看完整 Dock；点击预览后也可使用方向键")
            }
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
            HStack(spacing: 8) {
                Text("实际图标 \(dockPoints(actualIcon)) · 高度 \(dockPoints(g.barThickness)) · 间距 \(dockPoints(presentation.style.gap))")
                    .monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                if adjusted {
                    Text("受可用空间限制").lineLimit(1)
                        .help("请求图标 \(dockPoints(requestedIcon))，当前屏幕和 Dock 长度下实际为 \(dockPoints(actualIcon))。预览缩放保持 \(Int(zoom * 100))%。")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsPreviewImages {
    let isGroup: Bool
    let images: [NSImage]
}

private struct SettingsPreviewCanvas: NSViewRepresentable {
    let geometry: DockGeometry
    let zoom: CGFloat
    let focus: DockPreviewFocus
    let images: [SettingsPreviewImages]

    func makeNSView(context: Context) -> SettingsPreviewCanvasView { SettingsPreviewCanvasView() }
    func updateNSView(_ view: SettingsPreviewCanvasView, context: Context) {
        view.update(geometry: geometry, zoom: zoom, focus: focus, images: images)
    }
}

/// One drawing surface avoids stale per-entry frames and competing nested scroll views.
private final class SettingsPreviewCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var geometry: DockGeometry?
    private var zoom: CGFloat = 0.75
    private var focus: DockPreviewFocus = .none
    private var images: [SettingsPreviewImages] = []
    private var scrollOffset = CGPoint.zero
    private let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))

    private var previewLayout: SettingsPreviewLayout? {
        geometry.map { SettingsPreviewLayout(geometry: $0, zoom: zoom, viewportSize: bounds.size,
                                             scrollOffset: scrollOffset) }
    }

    func update(geometry: DockGeometry, zoom: CGFloat, focus: DockPreviewFocus, images: [SettingsPreviewImages]) {
        if self.geometry?.edge != geometry.edge { scrollOffset = .zero }
        self.geometry = geometry
        self.zoom = zoom
        self.focus = focus
        self.images = images
        scrollOffset = previewLayout?.scrollOffset ?? .zero
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scrollOffset = previewLayout?.scrollOffset ?? .zero
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = previewLayout, let geometry else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let corner = min(14, geometry.barThickness * layout.scale * 0.28)
        let bar = NSBezierPath(roundedRect: layout.backdropFrame, xRadius: corner, yRadius: corner)
        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill()
        bar.fill()
        (focus == .height || focus == .length ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        bar.lineWidth = focus == .height || focus == .length ? 1 : 0.5
        bar.stroke()
        guard !layout.visibleDockFrame.isNull else { return }
        NSBezierPath(rect: layout.visibleDockFrame).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        if let divider = layout.dividerFrame {
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: divider).fill()
        }
        for (index, rect) in layout.iconFrames.enumerated() where images.indices.contains(index) {
            guard rect.intersects(layout.visibleDockFrame) else { continue }
            let entry = images[index]
            if entry.isGroup {
                drawImage(folder, in: rect)
                let centers: [CGFloat] = entry.images.count == 1 ? [0.5] : entry.images.count == 2 ? [0.37, 0.63] : [0.29, 0.5, 0.71]
                for (index, image) in entry.images.enumerated() {
                    let side = rect.width * 0.31
                    drawImage(image, in: CGRect(x: rect.minX + centers[index] * rect.width - side / 2,
                        y: rect.minY + rect.height * 0.48, width: side, height: side))
                }
            } else {
                drawImage(entry.images.first, in: rect)
            }
            if focus == .size {
                let outline = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
                outline.setLineDash([3, 2], count: 2, phase: 0)
                outline.lineWidth = 0.75
                NSColor.controlAccentColor.setStroke()
                outline.stroke()
            }
        }
    }

    private func drawImage(_ image: NSImage?, in rect: CGRect) {
        image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let geometry, let layout = previewLayout else { super.scrollWheel(with: event); return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let dx = event.scrollingDeltaX * factor, dy = event.scrollingDeltaY * factor
        let along: CGFloat
        let across: CGFloat
        if geometry.edge.isHorizontal {
            along = layout.maximumScrollOffset.y > 0 || abs(dx) > abs(dy) ? dx : dy
            across = layout.maximumScrollOffset.y > 0 ? dy : 0
        } else {
            along = dy
            across = dx
        }
        if !pan(by: CGPoint(x: -along, y: -across)) { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        let horizontal = geometry?.edge.isHorizontal ?? true
        let delta: CGPoint
        switch event.keyCode {
        case 123: delta = horizontal ? CGPoint(x: -40, y: 0) : CGPoint(x: 0, y: -40)
        case 124: delta = horizontal ? CGPoint(x: 40, y: 0) : CGPoint(x: 0, y: 40)
        case 125: delta = horizontal ? CGPoint(x: 0, y: 40) : CGPoint(x: 40, y: 0)
        case 126: delta = horizontal ? CGPoint(x: 0, y: -40) : CGPoint(x: -40, y: 0)
        default: super.keyDown(with: event); return
        }
        _ = pan(by: delta)
    }

    @discardableResult private func pan(by delta: CGPoint) -> Bool {
        let previous = scrollOffset
        scrollOffset.x += delta.x
        scrollOffset.y += delta.y
        scrollOffset = previewLayout?.scrollOffset ?? .zero
        if scrollOffset != previous { needsDisplay = true }
        return scrollOffset != previous
    }
}

func edgeTitle(_ edge: DockEdge) -> String {
    switch edge { case .bottom: return "底部"; case .left: return "左侧"; case .right: return "右侧"; case .top: return "顶部" }
}
