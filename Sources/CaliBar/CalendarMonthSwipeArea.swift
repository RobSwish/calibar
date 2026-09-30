import AppKit
import CaliBarCore
import SwiftUI

/// Observes only trackpad scrolling inside the main calendar, without covering
/// buttons or taking vertical scrolling away from the appointment list.
struct CalendarMonthSwipeArea: NSViewRepresentable {
    let isEnabled: Bool
    let moveMonth: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) {
        view.isEnabled = isEnabled
        view.moveMonth = moveMonth
    }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stopMonitoring() }

    final class SwipeView: NSView {
        var isEnabled = true
        var moveMonth: ((Int) -> Void)?
        private var gesture = CalendarMonthSwipe()
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = CalendarMonthSwipe()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window, window.isVisible, event.window === window,
                  event.hasPreciseScrollingDeltas,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
            let phase: CalendarMonthSwipe.Phase
            if !event.momentumPhase.isEmpty { phase = .momentum }
            else if event.phase.contains(.began) { phase = .began }
            else if event.phase.contains(.cancelled) { phase = .cancelled }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.changed) { phase = .changed }
            else { return event }
            let result = gesture.update(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY, phase: phase)
            if let offset = result.monthOffset { moveMonth?(offset) }
            return result.consumesEvent ? nil : event
        }
    }
}
