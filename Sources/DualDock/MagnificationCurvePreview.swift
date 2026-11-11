import SwiftUI
import DualDockCore

/// Uses the same curve as DockGeometry; sample dots represent nearby icons.
struct MagnificationCurvePreview: View {
    let peak: Double
    let radius: Double
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(enabled ? "曲线预览" : "曲线预览 · 放大已关闭")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Canvas { context, size in
                let curve = DockMagnificationCurve(radius: CGFloat(radius))
                let effectivePeak: CGFloat = enabled ? CGFloat(peak) : 1
                let inset: CGFloat = 8
                let baseline = size.height - 8
                let amplitude = max(0, size.height - 20) / 1.5
                func point(_ distance: CGFloat) -> CGPoint {
                    CGPoint(x: inset + (distance + 4) / 8 * max(0, size.width - 2 * inset),
                            y: baseline - (curve.scale(atDistance: distance, peak: effectivePeak) - 1) * amplitude)
                }

                var baselinePath = Path()
                baselinePath.move(to: point(-4))
                baselinePath.addLine(to: point(4))
                context.stroke(baselinePath, with: .color(.secondary.opacity(0.3)), lineWidth: 1)

                var centerPath = Path()
                centerPath.move(to: CGPoint(x: size.width / 2, y: 6))
                centerPath.addLine(to: CGPoint(x: size.width / 2, y: baseline))
                context.stroke(centerPath, with: .color(.secondary.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                var line = Path()
                line.move(to: point(-4))
                for step in 1...160 { line.addLine(to: point(-4 + CGFloat(step) / 20)) }
                var fill = line
                fill.addLine(to: CGPoint(x: point(4).x, y: baseline))
                fill.addLine(to: CGPoint(x: point(-4).x, y: baseline))
                fill.closeSubpath()
                context.fill(fill, with: .color(.accentColor.opacity(0.1)))
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for index in -4...4 {
                    let center = point(CGFloat(index))
                    let side: CGFloat = index == 0 ? 6 : 4
                    let dot = Path(ellipseIn: CGRect(x: center.x - side / 2, y: center.y - side / 2,
                                                    width: side, height: side))
                    context.fill(dot, with: .color(.accentColor))
                }
            }
            .frame(height: 100)
            HStack {
                Text("较远")
                Spacer()
                Text("指针位置")
                Spacer()
                Text("较远")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("放大曲线预览")
        .accessibilityValue(enabled
            ? String(format: "峰值 %.0f%%，联动范围左右各 %.1f 个图标", peak * 100, radius)
            : "放大已关闭")
    }
}
