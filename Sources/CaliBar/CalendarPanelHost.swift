import AppKit
import SwiftUI

/// Uses the same native glass and content tint as Eluma's menu bar panel.
@MainActor
final class CalendarPanelHost<Content: View>: NSViewController {
    private let host: NSHostingController<Content>
    private let cornerRadius: CGFloat = 22

    init(content: Content) {
        host = NSHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        addChild(host)
        let frame = NSRect(x: 0, y: 0, width: 368, height: 640)
        host.view.frame = frame
        host.view.autoresizingMask = [.width, .height]

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            clipContent(in: glass)
            glass.contentView = host.view
            view = glass
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            clipContent(in: material)
            material.addSubview(host.view)
            view = material
        }
    }

    private func clipContent(in container: NSView) {
        // The effect rounds its surface; also clip the hosted content so it
        // cannot cover the glass with square corners.
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true
    }
}
