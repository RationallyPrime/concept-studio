import PrevisCore

enum ShotsSelection: Equatable, Sendable {
    case none
    case entities([EntityID])
    case camera
    case actorMark(EntityID, MarkID)
    case cameraMark(MarkID)

    var entityIDs: [EntityID] {
        if case let .entities(ids) = self { return ids }
        return []
    }
}
