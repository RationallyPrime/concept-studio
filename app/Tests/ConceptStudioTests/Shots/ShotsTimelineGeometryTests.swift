@testable import ConceptStudio
import PrevisCore
import Testing

@Suite("Shots timeline frame mapping")
struct ShotsTimelineGeometryTests {
    @Test func theRulerMapsEveryFrameAndClampsBothEdges() {
        let scale = ShotsTimelineGeometry(frameCount: 124, width: 615)
        for frame in 0 ..< 124 {
            let position = scale.position(atTime: FrameGrid.time(ofFrame: frame))
            #expect(scale.frame(atPosition: position) == frame)
        }
        #expect(scale.frame(atPosition: -100) == 0)
        #expect(scale.frame(atPosition: 900) == 123)
        #expect(scale.frame(atPosition: 62.5) == 13)
        #expect(ShotsTimelineGeometry(frameCount: 124, width: 0).frame(atPosition: 100) == 0)
    }

    @Test func movingAMarkPreservesItsHoldAndSnapsBeforeTheEnd() {
        let scale = ShotsTimelineGeometry(frameCount: 124, width: 615)
        #expect(scale.movedTime(from: 1, hold: 0.5, delta: 12.5) == FrameGrid.time(ofFrame: 27))
        #expect(scale.movedTime(from: 1, hold: 0.5, delta: 1000) == FrameGrid.time(ofFrame: 111))
        #expect(scale.movedTime(from: 1, hold: 0.5, delta: -1000) == 0)
    }

    @Test func stretchingAHoldLeavesTheMarkTimeAndFitsTheShot() {
        let scale = ShotsTimelineGeometry(frameCount: 124, width: 615)
        #expect(scale.stretchedHold(from: 0.5, time: 1, delta: 12.5) == FrameGrid.time(ofFrame: 15))
        #expect(scale.stretchedHold(from: 0.5, time: 1, delta: 1000) == FrameGrid.time(ofFrame: 99))
        #expect(scale.stretchedHold(from: 0.5, time: 1, delta: -1000) == 0)
        // Blocking is shared: marks beyond this shot stay in the document. An explicit hold drag stays nonnegative.
        #expect(scale.stretchedHold(from: 1, time: 8, delta: 10) == 0)
    }
}
