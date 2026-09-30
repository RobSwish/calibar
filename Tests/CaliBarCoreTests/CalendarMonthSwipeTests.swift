import Testing
@testable import CaliBarCore

@Suite("Calendar trackpad navigation")
struct CalendarMonthSwipeTests {
    @Test func horizontalSwipeAdvancesOnlyOnceIncludingMomentum() {
        var swipe = CalendarMonthSwipe()
        #expect(swipe.update(horizontal: -20, vertical: 1, phase: .began).monthOffset == nil)
        #expect(swipe.update(horizontal: -30, vertical: 1, phase: .changed).monthOffset == 1)
        #expect(swipe.update(horizontal: -90, vertical: 0, phase: .changed).monthOffset == nil)
        #expect(swipe.update(horizontal: 0, vertical: 0, phase: .ended).consumesEvent)
        #expect(swipe.update(horizontal: -100, vertical: 0, phase: .momentum).monthOffset == nil)
        #expect(swipe.update(horizontal: 50, vertical: 0, phase: .began).monthOffset == -1)
    }

    @Test func verticalScrollStaysVerticalDespiteLaterDrift() {
        var swipe = CalendarMonthSwipe()
        #expect(!swipe.update(horizontal: 2, vertical: 20, phase: .began).consumesEvent)
        let drift = swipe.update(horizontal: 100, vertical: 1, phase: .changed)
        #expect(!drift.consumesEvent)
        #expect(drift.monthOffset == nil)
        #expect(!swipe.update(horizontal: 50, vertical: 30, phase: .momentum).consumesEvent)
    }

    @Test func smallAndDiagonalMovementsDoNotNavigate() {
        var swipe = CalendarMonthSwipe()
        #expect(swipe.update(horizontal: 4, vertical: 1, phase: .began).monthOffset == nil)
        #expect(swipe.update(horizontal: 0, vertical: 0, phase: .cancelled).monthOffset == nil)
        #expect(swipe.update(horizontal: 40, vertical: 40, phase: .began).monthOffset == nil)
        #expect(swipe.update(horizontal: 10, vertical: 10, phase: .changed).monthOffset == nil)
        #expect(swipe.update(horizontal: -46, vertical: 1, phase: .began).monthOffset == 1)
    }
}
