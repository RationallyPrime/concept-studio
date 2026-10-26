import Foundation
import PrevisCore

/// Adapted from Blockout src/renderer/panels/Timeline.tsx at 3f2d0564 (Apache-2.0).
/// The source maps horizontal deltas to shot seconds; Shots additionally snaps edits to 24fps frames.
struct ShotsTimelineGeometry {
    let frameCount: Int
    let width: Double

    private var lastFrame: Int {
        max(0, frameCount - 1)
    }

    private var duration: Double {
        FrameGrid.time(ofFrame: lastFrame)
    }

    func position(atTime time: Double) -> Double {
        guard duration > 0, width > 0, width.isFinite, time.isFinite else { return 0 }
        return min(max(time / duration, 0), 1) * width
    }

    func frame(atPosition position: Double) -> Int {
        guard width > 0, width.isFinite, position.isFinite else { return 0 }
        let time = min(max(position / width, 0), 1) * duration
        return min(lastFrame, FrameGrid.frame(atTime: time))
    }

    func movedTime(from time: Double, hold: Double, delta: Double) -> Double {
        let proposed = translatedFrame(from: time, delta: delta)
        return FrameGrid.time(ofFrame: min(proposed, framesFitting(in: duration - hold)))
    }

    func stretchedHold(from hold: Double, time: Double, delta: Double) -> Double {
        let proposed = translatedFrame(from: hold, delta: delta)
        return FrameGrid.time(ofFrame: min(proposed, framesFitting(in: duration - time)))
    }

    private func translatedFrame(from seconds: Double, delta: Double) -> Int {
        guard duration > 0 else { return 0 }
        // Do not clamp the original value before adding the delta: shared blocking can exceed this shot.
        return frame(atPosition: seconds / duration * width + delta)
    }

    private func framesFitting(in seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        // A tiny arithmetic tolerance preserves exact frame endpoints represented as seconds.
        return min(lastFrame, max(0, Int((max(0, seconds) * Double(FrameGrid.fps) + 1e-9).rounded(.down))))
    }
}
