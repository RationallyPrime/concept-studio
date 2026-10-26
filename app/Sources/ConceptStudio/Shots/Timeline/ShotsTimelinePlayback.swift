import PrevisCore

/// Blockout SceneManager.ts loops playback; the native clock presents every Shots frame at 24fps.
enum ShotsTimelinePlayback {
    static func frame(startingAt first: Int, count: Int, elapsed: Double) -> Int {
        guard count > 0, elapsed.isFinite, elapsed >= 0 else { return 0 }
        let advances = (elapsed * Double(FrameGrid.fps)).truncatingRemainder(dividingBy: Double(count))
        return (max(0, first) % count + Int((advances + 1e-9).rounded(.down))) % count
    }
}
