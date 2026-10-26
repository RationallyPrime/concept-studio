import Foundation
@testable import PrevisCore
import Testing

struct ActionPathTests {
    private let man = PrevisEntity(
        id: "e",
        assetID: "person.man",
        name: "Man",
        placement: Placement(position: Vec3(2, 0, -3), heading: 0.7, scale: 1)
    )

    private func marks(
        _ id: String,
        start: Double = 0,
        duration: Double = 4,
        speed: Double? = nil
    ) throws -> [ActorMark] {
        try ActionPaths.marks(id, entity: man, startTime: start, duration: duration, speed: speed, catalog: .bundled())
    }

    @Test func marksStartAtTheEntityAndTheStartTimeWithFreshIDs() throws {
        let first = try marks("walk-forward", start: 1.5)
        let second = try marks("walk-forward", start: 1.5)
        #expect(first.first?.time == 1.5 && abs((first.last?.time ?? 0) - 5.5) < 1e-12)
        #expect(first.first?.position == Vec3(2, 0, -3))
        #expect(Set(first.map(\.id)).count == first.count && Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }

    @Test func aSpeedSetsTheAverageSpeedAlongTheMarks() throws {
        let flyby = try marks("plane-flyby", duration: 5, speed: 30)
        let length = zip(flyby, flyby.dropFirst()).reduce(0) { $0 + distance($1.0.position, $1.1.position) }
        #expect(abs(length / (flyby.last?.time ?? 1) - 30) < 1e-9)
    }

    @Test func unknownAndNonsensicalRequestsFailWithASentence() {
        #expect(throws: ShotsError.self) { try marks("no-such-path") }
        #expect(throws: ShotsError.self) { try marks("walk-forward", duration: 0) }
        #expect(throws: ShotsError.self) { try marks("walk-forward", speed: -1) }
    }
}
