import Foundation

// A shot's own blocking, CONTRACTS section 5.9. The shots of a scene share one take, so one performance can be
// covered from several cameras. A shot that stages people differently needs its own: it gets a copy of the take,
// and everyone's place is written into both takes as a mark at the first frame, so moving someone in one shot no
// longer moves them in the other.

public extension PrevisScene {
    /// The shots that share `shotID`'s take, itself included, in scene order.
    func shotsSharingBlocking(with shotID: ShotID) -> [Shot] {
        guard let take = shots.first(where: { $0.id == shotID })?.blockingTakeID else { return [] }
        return shots.filter { $0.blockingTakeID == take }
    }

    /// Gives a shot its own take, `takeID`, when it shares one with another shot; otherwise changes nothing.
    /// Every actor without marks is first pinned where it stands, in the shared take and so in the copy: its
    /// placement becomes a standing mark at time 0. An attached entity is left to ride its parent. The copy's marks
    /// get ids made from `takeID`, so the same call always gives the same scene.
    @discardableResult
    mutating func giveOwnBlocking(to shotID: ShotID, takeID: TakeID) -> TakeID? {
        guard let shotIndex = shots.firstIndex(where: { $0.id == shotID }) else { return nil }
        let sharedID = shots[shotIndex].blockingTakeID
        guard let takeIndex = blocking.firstIndex(where: { $0.id == sharedID }) else { return nil }
        guard shots.contains(where: { $0.id != shotID && $0.blockingTakeID == sharedID }) else { return sharedID }
        pinActors(inTake: takeIndex)
        var copy = blocking[takeIndex]
        copy.id = takeID
        copy.name = shots[shotIndex].name
        var counter = 0
        for track in copy.tracks.indices {
            for mark in copy.tracks[track].marks.indices {
                counter += 1
                copy.tracks[track].marks[mark].id = "\(takeID)_m\(counter)"
            }
        }
        blocking.append(copy)
        shots[shotIndex].blockingTakeID = takeID
        return takeID
    }

    /// Pins every unmarked actor in every take, once the scene has more than one: someone added after the takes
    /// parted then has a place of their own in each, and moving them in one shot leaves the others alone.
    mutating func pinActorsWhenTakesDiffer() {
        guard blocking.count > 1 else { return }
        for index in blocking.indices {
            pinActors(inTake: index)
        }
    }

    /// Writes each unmarked actor's placement into the take as a standing mark at time 0.
    internal mutating func pinActors(inTake takeIndex: Int) {
        let takeID = blocking[takeIndex].id
        for entity in entities where entity.setPiece == nil && entity.attachment == nil {
            let pin = ActorMark(
                id: "\(takeID)_\(entity.id)_pin", time: 0, hold: 0, easeIn: 0, easeOut: 0,
                position: entity.placement.position, gait: .stand, arriveHeading: entity.placement.heading
            )
            if let track = blocking[takeIndex].tracks.firstIndex(where: { $0.entityID == entity.id }) {
                if blocking[takeIndex].tracks[track].marks.isEmpty { blocking[takeIndex].tracks[track].marks = [pin] }
            } else {
                blocking[takeIndex].tracks.append(Track(entityID: entity.id, marks: [pin]))
            }
        }
    }
}
