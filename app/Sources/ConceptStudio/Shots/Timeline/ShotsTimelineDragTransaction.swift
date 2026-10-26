/// A cancelled pointer gesture stays cancelled until release, even if more movement callbacks arrive.
struct ShotsTimelineDragTransaction {
    private enum Phase {
        case idle, active(ShotsTimelineDrag), cancelled
    }

    private var phase = Phase.idle

    var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    mutating func update(
        mark: ShotsTimelineDrag.Mark,
        mode: ShotsTimelineDrag.Mode,
        geometry: ShotsTimelineGeometry,
        delta: Double
    ) -> ShotsCommand? {
        switch phase {
        case .cancelled: return nil
        case .idle:
            phase = .active(ShotsTimelineDrag(mark: mark, mode: mode, geometry: geometry))
        case .active: break
        }
        guard case let .active(drag) = phase else { return nil }
        return drag.command(delta: delta)
    }

    mutating func cancel() {
        if case .active = phase { phase = .cancelled }
    }

    mutating func finish(delta: Double) -> ShotsCommand? {
        defer { phase = .idle }
        guard case let .active(drag) = phase else { return nil }
        return drag.command(delta: delta)
    }

    mutating func reset() {
        phase = .idle
    }
}
