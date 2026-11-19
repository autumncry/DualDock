import AppKit
import SwiftUI
import DualDockCore

enum DockPreviewFocus: Equatable { case none, size, density, length, height }

/// A fixed set of sample apps illustrates preferences without mirroring the
/// user's running applications, pins, groups or current Dock length.
enum SettingsDockExample {
    static let apps: [AppReference] = [
        .init(id: "com.apple.mail", name: "Mail", path: "/System/Applications/Mail.app"),
        .init(id: "com.apple.iCal", name: "Calendar", path: "/System/Applications/Calendar.app"),
        .init(id: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"),
        .init(id: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
        .init(id: "com.apple.Music", name: "Music", path: "/System/Applications/Music.app")
    ]
    static let entries = apps.map { DockEntry(name: $0.name, apps: [$0]) }

    static func geometry(preferences: DockCustomSizing, edge: DockEdge,
                         nativeMetrics: NativeDockMetrics? = nil,
                         contentBounds: [CGRect]) -> DockGeometry {
        // These virtual dimensions keep length modes illustrative. The example
        // never inherits the real screen's app count or an old absolute length.
        let length: Double = edge.isHorizontal ? 900 : 600
        if let nativeMetrics {
            let style = DockGeometryStyle(iconSize: nativeMetrics.iconSize,
                barThickness: nativeMetrics.barThickness, gap: nativeMetrics.itemSpacing,
                leadingPadding: nativeMetrics.leadingPadding, trailingPadding: nativeMetrics.trailingPadding,
                separatorLength: 0, magnificationScale: 1)
            return .make(count: apps.count, edge: edge, style: style, maximumLength: length)
        }
        var example = preferences
        example.legacyFixedLength = nil
        let resolved = DockCustomSizingResolver.resolve(example, count: apps.count, dividerIndex: nil,
            maximumLength: length, maximumHeight: max(240, example.minimumHeightOverride ?? 0),
            contentBounds: contentBounds, edge: edge)
        let style = DockGeometryStyle(iconSize: resolved.iconSize, barThickness: resolved.thickness,
            gap: resolved.gap, leadingPadding: resolved.padding, trailingPadding: resolved.padding,
            separatorLength: 0, magnificationScale: 1, contentAlignment: example.alignment,
            contentBounds: contentBounds, spacingPercent: example.spacingPercent.map { CGFloat($0) })
        return .make(count: apps.count, edge: edge, style: style,
                     maximumLength: length, fixedLength: resolved.length)
    }
}

struct SettingsDockPreview: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    let displayID: String?
    var focus: DockPreviewFocus = .none

    private var edge: DockEdge { displayID.map { store.edge(for: $0) } ?? .bottom }
    // Fixed per orientation, never auto-fit while a slider is being adjusted.
    private var zoom: CGFloat { edge.isHorizontal ? 0.75 : 0.45 }
    var exampleGeometry: DockGeometry {
        SettingsDockExample.geometry(
            preferences: store.configuration.adaptiveSizing ? DockCustomSizing() : store.customSizing(for: displayID),
            edge: edge, nativeMetrics: store.configuration.adaptiveSizing ? store.nativeDockMetrics : nil,
            contentBounds: store.contentBounds(for: SettingsDockExample.entries))
    }

    var body: some View {
        let g = exampleGeometry
        // Reserve the space the sample needs. Large values can still pan at
        // the fixed rendering scale; the preview never fits icons by shrinking.
        let stage: CGFloat = edge.isHorizontal
            ? min(152, max(80, ceil(g.barThickness * zoom) + 28))
            : 146
        GeometryReader { proxy in
            let viewport = CGSize(width: proxy.size.width, height: stage)
            let layout = SettingsPreviewLayout(geometry: g, zoom: zoom, viewportSize: viewport)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(g.edge.isHorizontal ? localize("布局示例", "Sample Dock") : localize("\(edgeTitle(edge))示例", "\(edgeTitle(edge)) Dock"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    if layout.maximumScrollOffset.x > 0 {
                        if g.edge.isHorizontal {
                            Text(localize("左右滚动", "Scroll horizontally"))
                            Text("·").accessibilityHidden(true)
                        } else {
                            Image(systemName: "arrow.up.and.down")
                                .accessibilityLabel(localize("上下滚动查看示例", "Scroll vertically to see more"))
                        }
                    }
                    if g.edge.isHorizontal { Text(edgeTitle(edge)) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                SettingsPreviewCanvas(geometry: g, zoom: zoom, focus: focus,
                    images: SettingsDockExample.apps.map { store.icon(for: $0) })
                    .frame(height: stage)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(localize("布局示例，\(edgeTitle(edge)) Dock，五个固定示例图标",
                                                 "Sample Dock at the \(edgeTitle(edge).lowercased()) edge with five example icons"))
                    .help(localize("滚动查看完整示例；点击示例后也可使用方向键", "Scroll to see the full example, or click it and use the arrow keys"))
            }
        }
        .frame(height: 28 + stage)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }
}

private struct SettingsPreviewCanvas: NSViewRepresentable {
    let geometry: DockGeometry
    let zoom: CGFloat
    let focus: DockPreviewFocus
    let images: [NSImage]

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
    private var images: [NSImage] = []
    private var scrollOffset = CGPoint.zero

    private var previewLayout: SettingsPreviewLayout? {
        geometry.map { SettingsPreviewLayout(geometry: $0, zoom: zoom, viewportSize: bounds.size,
                                             scrollOffset: scrollOffset) }
    }

    func update(geometry: DockGeometry, zoom: CGFloat, focus: DockPreviewFocus, images: [NSImage]) {
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
            drawImage(images[index], in: rect)
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
    switch edge { case .bottom: return L("底部", "Bottom"); case .left: return L("左侧", "Left"); case .right: return L("右侧", "Right"); case .top: return L("顶部", "Top") }
}
