import Foundation

public enum DockMenuPlacement {
    public static func origin(icon: CGRect, menuSize: CGSize, visibleScreen: CGRect) -> CGPoint {
        let available = visibleScreen.insetBy(dx: 8, dy: 8)
        let x = max(available.minX, min(icon.midX + 8, available.maxX - menuSize.width))
        let y = min(icon.maxY + 8 + menuSize.height, available.maxY)
        return CGPoint(x: x, y: y)
    }
}
