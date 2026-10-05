import AppKit
import QuartzCore

/// Keeps AppKit's native status button, including its hit target and accessibility.
@MainActor
final class StatusItemPresentation {
    private let item: NSStatusItem
    private var title = ""
    private var joining = false
    private var reservedLength: CGFloat?
    private var transition: Task<Void, Never>?
    private var overlay: StatusItemTransitionView?

    init(item: NSStatusItem) {
        self.item = item
        item.button?.wantsLayer = true
    }

    func update(title: String, joining: Bool) {
        let changedState = self.joining != joining
        let previousState = self.joining
        self.title = title
        self.joining = joining
        guard changedState else {
            if overlay == nil { applyContent() }
            return
        }

        transition?.cancel()
        guard let button = item.button else { return }
        // Fixed lengths exclude AppKit's menu-bar padding. Using the button's
        // bounds here would add that padding twice and move neighbouring items.
        if reservedLength == nil {
            reservedLength = item.length >= 0 ? item.length : button.cell?.cellSize.width
        }
        if let reservedLength { item.length = reservedLength }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishTransition()
            return
        }

        if overlay == nil {
            let container = button.superview ?? button
            guard let previousImage = snapshot(button, in: container) else {
                finishTransition()
                return
            }
            applyContent(keepWidth: true)
            guard let nextImage = snapshot(button, in: container) else {
                finishTransition()
                return
            }
            let normalImage = previousState ? nextImage : previousImage
            let joinImage = previousState ? previousImage : nextImage
            let overlay = StatusItemTransitionView(frame: container.bounds,
                normalImage: normalImage, joinImage: joinImage, joining: previousState)
            self.overlay = overlay
            // Only replace the foreground while the snapshots overlap. The
            // native button/background stays fully opaque and remains clickable.
            button.image = nil
            button.title = ""
            container.addSubview(overlay)
        }
        overlay?.animate(joining: joining, duration: 0.22)
        transition = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                self?.finishTransition()
            } catch { /* Reverse the current crossfade when the hover changes. */ }
        }
    }

    private func applyContent(keepWidth: Bool = false) {
        guard let button = item.button else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let image = NSImage(systemSymbolName: joining ? "video.fill" : "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.title = title.isEmpty ? "" : " " + title
        if (joining || keepWidth), let reservedLength {
            item.length = reservedLength
        } else {
            // Use the same content-based sizing in both states so the native
            // button's internal padding never changes on hover.
            item.length = title.isEmpty ? NSStatusItem.squareLength
                : (button.cell?.cellSize.width ?? NSStatusItem.variableLength)
            reservedLength = nil
        }
        CATransaction.commit()
    }

    private func snapshot(_ button: NSStatusBarButton, in container: NSView) -> CGImage? {
        container.layoutSubtreeIfNeeded()
        // SF Symbols change the native button's height and vertical inset. Crop
        // each state into the same menu-bar coordinates instead of stretching
        // differently sized button snapshots into the transition's frame.
        let rect = button.convert(container.bounds, from: container)
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        button.cacheDisplay(in: rect, to: bitmap)
        return bitmap.cgImage
    }

    private func finishTransition() {
        transition = nil
        // Restore native drawing beneath the fully visible destination first.
        applyContent()
        overlay?.removeFromSuperview()
        overlay = nil
    }
}

@MainActor
private final class StatusItemTransitionView: NSView {
    private let normal = CALayer()
    private let join = CALayer()

    init(frame: NSRect, normalImage: CGImage, joinImage: CGImage, joining: Bool) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("CaliBarJoinTransition")
        autoresizingMask = [.width, .height]
        wantsLayer = true
        for (content, image, visible) in [(normal, normalImage, !joining), (join, joinImage, joining)] {
            content.frame = bounds
            content.contents = image
            content.contentsScale = CGFloat(image.width) / max(bounds.width, 1)
            content.contentsGravity = .center
            content.opacity = visible ? 1 : 0
            layer?.addSublayer(content)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func animate(joining: Bool, duration: Double) {
        animate(normal, visible: !joining, duration: duration)
        animate(join, visible: joining, duration: duration)
    }

    private func animate(_ content: CALayer, visible: Bool, duration: Double) {
        let presented = content.presentation() ?? content
        let startOpacity = presented.opacity
        let opacity: Float = visible ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.opacity = opacity
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        content.add(fade, forKey: "joinOpacity")
    }
}
