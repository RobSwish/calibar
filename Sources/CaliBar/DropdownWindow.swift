//
//  DropdownWindow.swift
//  Thora
//
//  Hosts a `DropdownPanel`'s rows in a borderless child window, so a dropdown is never clipped by the window
//  (or sheet) that owns it — the reason a long branch list read as cut off at the window's bottom edge.
//
//  It is NOT an `NSPopover`: no arrow, no system material, no popover behaviors. The window is transparent and
//  the panel's whole appearance is the SwiftUI content we put inside it, so it looks identical wherever it
//  opens. It is added as a CHILD of the owning window, so it follows that window as it moves and closes with it.
//
//  The window itself casts NO shadow (`hasShadow = false`): AppKit's window shadow has no radius or opacity
//  control and rendered as a thick grey band down the panel's edges. The shadow is drawn in SwiftUI instead
//  (`dropdownShadow()`), which is why the window is `CGFloat(24)` larger than the panel on every
//  side — a transparent ring for the shadow to fall into. All placement below is expressed in terms of the
//  VISIBLE panel; the margin is added back when the window frame is set.
//
//  Positioning is screen-aware: the panel hangs below its trigger, and flips above when the screen's bottom
//  edge doesn't leave room. Content measures itself (SwiftUI reports its size back through `resize(to:)`), so
//  the window keeps hugging the rows as a filter shrinks the list.
//

import AppKit
import SwiftUI

/// A borderless panel that can still take key focus — the filter field inside it has to be typeable.
final class DropdownPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that ignores clicks landing in the shadow margin, so the invisible ring around a dropdown
/// doesn't behave like part of the control.
private final class DropdownHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinates, so convert before testing against our own bounds.
        let local = convert(point, from: superview)
        let visible = bounds.insetBy(dx: CGFloat(24), dy: CGFloat(24))
        return visible.contains(local) ? super.hitTest(point) : nil
    }
}

@MainActor
final class DropdownWindow {

    /// Gap between the trigger and the panel.
    private static let gap = CGFloat(4)
    /// Keep the panel off the screen's own edges.
    private static let screenMargin = CGFloat(8)

    private var panel: DropdownPanelWindow?
    /// The trigger's frame in screen coordinates, captured when opening.
    private var anchor: NSRect = .zero
    /// Visible panel width (excludes the shadow margin).
    private var width: CGFloat = 0
    private var trailing = false
    private var screenFrame: NSRect = .zero
    private var closeObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onDismiss: (() -> Void)?

    var isOpen: Bool { panel != nil }

    /// The visible panel in screen coordinates — the window frame minus its shadow margin.
    private var visibleFrame: NSRect {
        guard let panel else { return .zero }
        return panel.frame.insetBy(dx: CGFloat(24), dy: CGFloat(24))
    }

    /// Adapted from the shared Nimble/Thimble dropdown. Show `content` under `anchor`. The content is a snapshot: a dropdown session is short, and its own
    /// filtering/highlight state lives inside the hosted tree, so it doesn't track later changes to the
    /// caller's data (reopening picks those up).
    func open(content: AnyView, anchor: NSRect, width: CGFloat, parent: NSWindow, trailing: Bool = false, onDismiss: @escaping () -> Void) {
        close()
        self.anchor = anchor
        self.trailing = trailing
        // A newly created panel starts at (0, 0), so its own screen can be a
        // different display. Position against the display containing the trigger.
        self.screenFrame = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
                            ?? parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        self.width = width
        self.onDismiss = onDismiss

        // Measure BEFORE the window exists. Opening at a placeholder size and resizing afterwards laid the
        // rows out twice, which showed as the content (the check glyph, the corner radius) jumping on appear.
        // AppKit-hosted: the scene roots' AutoFill opt-out doesn't reach here, so apply it again.
        let hosting = DropdownHostingView(rootView: content)
        let height = hosting.fittingSize.height

        let panel = DropdownPanelWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered,
                                        defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the shadow is SwiftUI's; see the file comment
        panel.level = .popUpMenu
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = true
        panel.appearance = parent.effectiveAppearance
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        self.panel = panel

        position(visibleHeight: height - CGFloat(24) * 2)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        startWatching()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
    }

    /// Re-place the window as the hosted content's height changes — filtering a long list down to two rows
    /// should shrink the panel, not leave it standing at its opening height. `size` includes the margin.
    func resize(to size: CGSize) {
        guard panel != nil else { return }
        position(visibleHeight: size.height - CGFloat(24) * 2)
    }

    func close() {
        stopWatching()
        onDismiss = nil
        guard let panel else { return }
        let parent = panel.parent
        let wasKey = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        if wasKey, parent?.isVisible == true { parent?.makeKey() }
    }

    // MARK: - Placement

    private func position(visibleHeight: CGFloat) {
        guard let panel, visibleHeight > 0 else { return }
        let screen = screenFrame
        let margin = CGFloat(24)

        // Below the trigger; flip above when the bottom of the screen doesn't leave room for the whole panel.
        var origin = CGPoint(x: trailing ? anchor.maxX - width : anchor.minX, y: anchor.minY - Self.gap - visibleHeight)
        if origin.y < screen.minY + Self.screenMargin {
            let above = anchor.maxY + Self.gap
            if above + visibleHeight <= screen.maxY - Self.screenMargin {
                origin.y = above
            } else {
                origin.y = screen.minY + Self.screenMargin      // neither side fits: sit on the screen edge
            }
        }
        origin.x = min(max(origin.x, screen.minX + Self.screenMargin),
                       max(screen.maxX - width - Self.screenMargin, screen.minX + Self.screenMargin))

        // Grow the frame outwards by the shadow margin on every side.
        let frame = NSRect(x: origin.x - margin, y: origin.y - margin,
                           width: width + margin * 2, height: visibleHeight + margin * 2)
        guard !frame.equalTo(panel.frame) else { return }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Dismissal

    /// A click or scroll anywhere outside the panel dismisses it, the way a menu does. Containment is tested
    /// against the VISIBLE panel, not the window, so a click in the shadow margin counts as outside. A click
    /// ON the trigger is swallowed, so the trigger's own action can't immediately reopen what this just closed.
    private func startWatching() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) {
            [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismiss(); return nil }
                return event
            }
            let point = NSEvent.mouseLocation
            if self.visibleFrame.contains(point) { return event }
            if event.type == .scrollWheel, event.window == nil { return event }

            let onTrigger = self.anchor.contains(point)
            self.dismiss()
            return onTrigger ? nil : event
        }
        // Switching apps (or anything else that deactivates us) should take the panel with it.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func stopWatching() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func dismiss() {
        let callback = onDismiss
        close()
        callback?()
    }
}
