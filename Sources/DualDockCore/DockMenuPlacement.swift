import Foundation

public enum DockMenuPlacement {
    public static func origin(icon: CGRect, menuSize: CGSize, visibleScreen: CGRect, edge: DockEdge = .bottom) -> CGPoint {
        let available = visibleScreen.insetBy(dx: 8, dy: 8)
        let desired: CGPoint
        switch edge {
        case .bottom: desired = CGPoint(x: icon.midX + 8, y: icon.maxY + 8 + menuSize.height)
        case .top: desired = CGPoint(x: icon.midX + 8, y: icon.minY - 8)
        case .left: desired = CGPoint(x: icon.maxX + 8, y: icon.midY + menuSize.height / 2)
        case .right: desired = CGPoint(x: icon.minX - 8 - menuSize.width, y: icon.midY + menuSize.height / 2)
        }
        let x = max(available.minX, min(desired.x, available.maxX - menuSize.width))
        let y = menuSize.height > available.height ? available.maxY
            : max(available.minY + menuSize.height, min(desired.y, available.maxY))
        return CGPoint(x: x, y: y)
    }
}
