@testable import ConceptStudio
import Testing

@Suite("Shots timeline playback clock")
struct ShotsTimelinePlaybackTests {
    @Test func aDelayedWakeUsesElapsedTimeRatherThanOneFramePerCallback() {
        #expect(ShotsTimelinePlayback.frame(startingAt: 0, count: 124, elapsed: 1.1) == 26)
        #expect(ShotsTimelinePlayback.frame(startingAt: 0, count: 124, elapsed: 0.04) == 0)
        #expect(ShotsTimelinePlayback.frame(startingAt: 0, count: 124, elapsed: 1.0 / 24) == 1)
    }

    @Test func theFinalFrameIsPresentedBeforeLoopingFromAnyStartingFrame() {
        #expect(ShotsTimelinePlayback.frame(startingAt: 20, count: 22, elapsed: 0) == 20)
        #expect(ShotsTimelinePlayback.frame(startingAt: 20, count: 22, elapsed: 1.0 / 24) == 21)
        #expect(ShotsTimelinePlayback.frame(startingAt: 20, count: 22, elapsed: 2.0 / 24) == 0)
        #expect(ShotsTimelinePlayback.frame(startingAt: 20, count: 22, elapsed: 0.5) == 10)
    }
}
