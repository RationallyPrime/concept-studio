import PrevisCore

enum ShotsSelection: Equatable, Sendable {
    case none
    case entities([EntityID])
    case camera
    case actorMark(EntityID, MarkID)
    case cameraMark(MarkID)
}
