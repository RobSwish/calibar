/// Locks a trackpad gesture to one axis and advances at most one month.
public struct CalendarMonthSwipe {
    public enum Phase { case began, changed, ended, cancelled, momentum }
    public struct Result {
        public let consumesEvent: Bool
        public let monthOffset: Int?
    }
    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var horizontal = 0.0
    private var vertical = 0.0
    private var navigated = false

    public init() {}

    public mutating func update(horizontal dx: Double, vertical dy: Double, phase: Phase) -> Result {
        if phase == .began { self = Self() }
        if phase == .momentum || phase == .ended || phase == .cancelled {
            return Result(consumesEvent: axis == .horizontal, monthOffset: nil)
        }
        horizontal += dx
        vertical += dy
        if axis == nil, max(abs(horizontal), abs(vertical)) >= 8 {
            if abs(horizontal) > abs(vertical) * 1.25 { axis = .horizontal }
            else if abs(vertical) > abs(horizontal) * 1.25 { axis = .vertical }
        }
        guard axis == .horizontal else { return Result(consumesEvent: false, monthOffset: nil) }
        guard !navigated, abs(horizontal) >= 45 else { return Result(consumesEvent: true, monthOffset: nil) }
        navigated = true
        return Result(consumesEvent: true, monthOffset: horizontal < 0 ? 1 : -1)
    }
}
