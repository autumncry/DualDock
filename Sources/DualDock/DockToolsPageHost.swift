import SwiftUI
import DualDockCore

private final class ToolShelfHostingView: NSHostingView<DockToolsShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension DockToolsStore: DockShelfToolsProviding {
    func makeSurface(on displayID: String, presentation: DockPresentation) -> DockShelfSurface {
        func shelf(_ edge: DockEdge, _ size: CGFloat) -> DockToolsShelfView {
            DockToolsShelfView(store: self, displayID: displayID, edge: edge, iconSize: size)
        }
        var edge = presentation.edge
        var size = presentation.style.iconSize
        let view = ToolShelfHostingView(rootView: shelf(edge, size))
        view.sizingOptions = []
        return DockShelfSurface(view: view) { [weak view] newEdge, newSize in
            guard edge != newEdge || size != newSize else { return }
            edge = newEdge
            size = newSize
            view?.rootView = shelf(edge, size)
        }
    }
}
