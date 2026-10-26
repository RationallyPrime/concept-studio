import PrevisCore

/// Blockout Timeline.tsx captures the original mark on pointer-down, previews locally, then commits once.
/// Keep the captured value so successive drag events never accumulate rounding or edit history.
struct ShotsTimelineDrag {
    enum Mark {
        case actor(ShotID, EntityID, ActorMark)
        case camera(ShotID, CameraMark)
    }

    enum Mode { case move, stretch }

    let mark: Mark
    let mode: Mode
    let geometry: ShotsTimelineGeometry

    func command(delta: Double) -> ShotsCommand {
        switch mark {
        case let .actor(shotID, entityID, original):
            var changed = original
            if mode == .move {
                changed.time = geometry.movedTime(from: original.time, hold: original.hold, delta: delta)
            } else {
                changed.hold = geometry.stretchedHold(from: original.hold, time: original.time, delta: delta)
            }
            return .updateActorMark(shotID, entityID, changed)
        case let .camera(shotID, original):
            var changed = original
            if mode == .move {
                changed.time = geometry.movedTime(from: original.time, hold: original.hold, delta: delta)
            } else {
                changed.hold = geometry.stretchedHold(from: original.hold, time: original.time, delta: delta)
            }
            return .updateCameraMark(shotID, changed)
        }
    }
}
