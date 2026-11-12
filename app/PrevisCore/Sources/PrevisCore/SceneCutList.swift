import Foundation

public struct SceneCut: Codable, Sendable, Equatable {
    public var shotID: ShotID
    public var startFrame: Int
    public var endFrame: Int // exclusive

    public init(shotID: ShotID, startFrame: Int, endFrame: Int) {
        self.shotID = shotID
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// One 24 fps edit, in scene shot order. Playback and export use the same half-open frame ranges.
public struct SceneCutList: Codable, Sendable, Equatable {
    public var frameRate: Int
    public var cuts: [SceneCut]

    public var frameCount: Int {
        cuts.last?.endFrame ?? 0
    }

    public init(frameRate: Int, cuts: [SceneCut] = []) {
        self.frameRate = frameRate
        self.cuts = cuts
    }

    public init(scene: PrevisScene) throws {
        var start = 0
        let cuts = try scene.shots.map { shot in
            let (end, overflow) = start.addingReportingOverflow(shot.editFrames)
            guard !overflow, (1 ... max(1, shot.frameCount)).contains(shot.editFrames), shot.frameCount > 0 else {
                throw ShotsError.invalid([ShotsProblem(
                    severity: .error, message: "Choose an edit length within the frames of “\(shot.name)”.",
                    sceneID: scene.id, shotID: shot.id
                )])
            }
            defer { start = end }
            return SceneCut(shotID: shot.id, startFrame: start, endFrame: end)
        }
        self.init(frameRate: FrameGrid.fps, cuts: cuts)
    }

    public func cut(at frame: Int) -> SceneCut? {
        cuts.first { $0.startFrame <= frame && frame < $0.endFrame }
    }
}
