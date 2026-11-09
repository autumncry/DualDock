import Foundation

public struct PreviewStripLayout {
    public let panelWidth: CGFloat
    public let viewportWidth: CGFloat
    public let documentWidth: CGFloat
    public let cardOrigins: [CGFloat]
    public let cardWidth: CGFloat = 192
    public let padding: CGFloat = 12

    public init?(itemCount: Int, maxWidth: CGFloat) {
        guard itemCount > 0, maxWidth.isFinite, maxWidth > 24 else { return nil }
        let contentWidth = CGFloat(itemCount) * cardWidth + CGFloat(itemCount - 1) * 10
        panelWidth = min(maxWidth, max(240, contentWidth + padding * 2))
        viewportWidth = panelWidth - padding * 2
        documentWidth = max(contentWidth, viewportWidth)
        let leadingSpace = (documentWidth - contentWidth) / 2
        cardOrigins = (0..<itemCount).map { leadingSpace + CGFloat($0) * 202 }
    }
}
