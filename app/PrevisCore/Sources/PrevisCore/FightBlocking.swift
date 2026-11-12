import Foundation

/// Schedules paired animation presets in an authored range of frames.
public enum FightBlocking: String, Codable, CaseIterable, Sendable {
    case swordExchange, jabCross, roundhouse, haymaker, uppercut, frontKick, highKick

    public var name: String {
        switch self {
        case .swordExchange: "Thrust and parry"
        case .jabCross: "Jab and reaction"
        case .roundhouse: "Roundhouse and reaction"
        case .haymaker: "Haymaker and stumble"
        case .uppercut: "Uppercut and block"
        case .frontKick: "Front kick and reaction"
        case .highKick: "High kick and reaction"
        }
    }

    private var pair: [(motion: String, cue: Double)] {
        switch self {
        case .swordExchange: [("sword-thrust", 0.55), ("sword-parry", 0.45)]
        case .jabCross: [("jab-cross", 0.3), ("hit-reaction-head", 0.2)]
        case .roundhouse: [("roundhouse-kick", 0.65), ("hit-reaction-body", 0.25)]
        case .haymaker: [("haymaker", 0.6), ("stumble-back-fall", 0.3)]
        case .uppercut: [("uppercut", 0.6), ("block-and-dodge", 0.35)]
        case .frontKick: [("front-kick-combo", 0.55), ("hit-reaction-head", 0.2)]
        case .highKick: [("high-kick", 0.6), ("hit-reaction-body", 0.25)]
        }
    }

    public func tracks(
        scene: PrevisScene, shot: Shot, actors: [EntityID], first: Int, last: Int, catalog: ContentCatalog
    ) throws -> [Track] {
        guard actors.count == 2, Set(actors).count == 2, first >= 0, last >= first, last < shot.frameCount,
              last - first >= 2 else {
            throw problem("Choose two people and an interval of at least three frames inside the shot.", shot)
        }
        guard let take = scene.blocking.first(where: { $0.id == shot.blockingTakeID }) else {
            throw problem("The shot has no blocking take.", shot)
        }
        let start = FrameGrid.time(ofFrame: first)
        let end = FrameGrid.time(ofFrame: last)
        let hit = FrameGrid.time(ofFrame: first + (last - first) / 2)
        return try zip(actors, pair).map { actorID, entry in
            guard let actor = scene.entities.first(where: { $0.id == actorID }),
                  catalog.asset(actor.assetID)?.rig == .person, actor.formation == nil else {
                throw problem("Fight blocking needs two individual people.", shot)
            }
            guard let motion = catalog.motion(entry.motion) else { throw ShotsError.unknownContent(entry.motion) }
            let current = take.tracks.first { $0.entityID == actorID }
            let staged = Motions.marks(motion, for: actor, track: current, at: start) { local in
                if local <= entry.cue { return lerp(start, hit, local / entry.cue) }
                return lerp(hit, end, (local - entry.cue) / (motion.duration - entry.cue))
            }
            let marks = current?.marks ?? []
            return Track(
                entityID: actorID,
                marks: marks.filter { $0.time < start } + staged + marks.filter { $0.time > end }
            )
        }
    }

    private func problem(_ message: String, _ shot: Shot) -> ShotsError {
        .invalid([ShotsProblem(severity: .error, message: message, shotID: shot.id)])
    }
}
