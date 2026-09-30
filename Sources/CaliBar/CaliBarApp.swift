import AppKit
import Combine
import CaliBarCore
import QuartzCore
import SwiftUI

@main
enum CaliBarApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel!
    private var panelTargetX: CGFloat?
    private var panelAnchorUpdateScheduled = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var model: CalendarModel!
    private var displayedMeetingURL: URL?
    private var statusHoverTimer: Timer?
    private var statusHoverWidth: CGFloat?
    private var optionHover = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit CaliBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        if demo && ProcessInfo.processInfo.arguments.contains("--dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        model = CalendarModel(demo: demo)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: .leftMouseUp)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let icon = NSImage(systemSymbolName: "calendar", accessibilityDescription: "CaliBar")?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            icon?.size = NSSize(width: 16, height: 16)
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("CaliBar calendar")
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }
        panel = MenuBarPanel()
        panel.appearance = NSApp.appearance
        panel.onDismiss = { [weak self] in self?.hidePanel() }
        panel.contentViewController = CalendarPanelHost(content: CalendarPanel(model: model))
        if let statusWindow = statusItem.button?.window {
            NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: statusWindow)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: statusWindow))
                .sink { [weak self] _ in
                    Task { @MainActor in self?.schedulePanelAnchorUpdate() }
                }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.hidePanel() } }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.hidePanel() } }
            .store(in: &cancellables)
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
            .store(in: &cancellables)
        updateStatus()
        if !model.syncEnabled || demo {
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    @objc private func togglePanel() {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if !modifiers.intersection([.command, .option]).isEmpty,
           let url = displayedMeetingURL {
            hidePanel()
            model.joinCall(url)
            return
        }
        if panel.isVisible { hidePanel() }
        else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let statusWindow = button.window,
              let screen = statusWindow.screen ?? NSScreen.main else { return }
        model.refresh()
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: 368, height: 640)
        let x = max(visible.minX, min(anchor.midX - size.width / 2, visible.maxX - size.width))
        let y = max(visible.minY, min(anchor.minY - 6, visible.maxY) - size.height)
        panelTargetX = x
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        panel.invalidateShadow()
        if model.isScreenshot {
            // AppKit may select the first text field even without SwiftUI focus.
            // Leave screenshot fixtures free of selection and insertion cursors.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.model.isScreenshot, self.panel.isVisible else { return }
                self.panel.makeFirstResponder(nil)
            }
        }
        statusItem.button?.highlight(true)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissForOutsideClick() }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let window = event.window,
                       window !== self.panel, window !== self.statusItem.button?.window {
                        self.dismissForOutsideClick()
                    }
                }
                return event
            }
        }
    }

    private func dismissForOutsideClick() {
        guard panel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        // A status-item mouse-down can reach the global monitor before the
        // button's mouse-up. Let togglePanel handle the whole click once.
        if let button = statusItem.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(pointer) { return }
        }
        if panel.frame.contains(pointer) { return }
        var descendants = panel.childWindows ?? []
        while let child = descendants.popLast() {
            if child.isVisible && child.frame.contains(pointer) { return }
            descendants.append(contentsOf: child.childWindows ?? [])
        }
        hidePanel()
    }

    private func hidePanel() {
        panel?.childWindows?.forEach { $0.close() }
        panel?.orderOut(nil)
        panelTargetX = nil
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusHoverTimer?.invalidate()
        hidePanel()
    }

    @objc(mouseEntered:) func statusMouseEntered(_ event: NSEvent) {
        statusHoverWidth = statusItem.button?.bounds.width
        updateOptionHover()
        statusHoverTimer?.invalidate()
        // Poll modifier state only while hovering: this also works when another
        // app is active, without requesting global keyboard-monitoring access.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOptionHover() }
        }
        statusHoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc(mouseExited:) func statusMouseExited(_ event: NSEvent) {
        endStatusHover()
    }

    private func updateOptionHover() {
        guard let button = statusItem.button, let window = button.window,
              window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) else {
            endStatusHover()
            return
        }
        let value = NSEvent.modifierFlags.contains(.option)
        guard value != optionHover else { return }
        optionHover = value
        updateStatus()
    }

    private func endStatusHover() {
        statusHoverTimer?.invalidate()
        statusHoverTimer = nil
        statusHoverWidth = nil
        optionHover = false
        updateStatus()
    }

    private func updateStatus() {
        let nextEvent = model.nextEvent
        displayedMeetingURL = model.menuBarPreferences.showsNextEvent ? nextEvent?.meeting?.url : nil
        let quickJoin = optionHover && displayedMeetingURL != nil
        let title = quickJoin ? "Join" : MenuBarDisplay.title(now: model.now, preferences: model.menuBarPreferences, nextEvent: nextEvent)
        // Keep the hover target stationary when the event title becomes Join.
        statusItem.length = quickJoin ? max(statusHoverWidth ?? 0, 64) : (title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength)
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.title = title.isEmpty ? "" : " " + title
        if model.menuBarPreferences.showsNextEvent, let event = nextEvent {
            let joinHint = displayedMeetingURL == nil ? "" : "\n⌥-click or ⌘-click to join"
            statusItem.button?.toolTip = "\(event.title) · \(event.start.formatted(date: .abbreviated, time: .shortened))\(joinHint)"
            statusItem.button?.setAccessibilityLabel(quickJoin ? "Join \(event.title)" : "CaliBar. Next event: \(event.title), \(event.start.formatted(date: .complete, time: .shortened))")
        } else {
            statusItem.button?.toolTip = "CaliBar — your calendars"
            statusItem.button?.setAccessibilityLabel("CaliBar calendar. \(model.now.formatted(date: .complete, time: .omitted))")
        }
        schedulePanelAnchorUpdate()
    }

    private func schedulePanelAnchorUpdate() {
        guard panel?.isVisible == true, !panelAnchorUpdateScheduled else { return }
        panelAnchorUpdateScheduled = true
        // Coalesce model changes and let AppKit lay out the new status-item width.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panelAnchorUpdateScheduled = false
            self.updatePanelAnchor()
        }
    }

    private func updatePanelAnchor() {
        guard panel?.isVisible == true, let button = statusItem.button,
              let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = max(visible.minX, min(anchor.midX - panel.frame.width / 2, visible.maxX - panel.frame.width))
        // Repeated refresh notifications must not restart an in-flight move.
        guard abs(x - (panelTargetX ?? panel.frame.minX)) >= 0.5 else { return }
        panelTargetX = x
        var frame = panel.frame
        frame.origin.x = x
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

@MainActor
private final class MenuBarPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 368, height: 640),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "CaliBar"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    // Child dropdowns become key for search and keyboard navigation. Keeping
    // the calendar as the main window preserves its native active appearance.
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
