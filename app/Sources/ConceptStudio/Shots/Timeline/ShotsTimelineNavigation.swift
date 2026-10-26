import PrevisCore

enum ShotsTimelineKey {
    case backward, forward, home, end, delete
}

extension ShotsStore {
    /// CONTRACTS section 7 narrows Blockout App.tsx keyboard handling to the focused region.
    @discardableResult
    func navigateTimeline(_ key: ShotsTimelineKey, focused: Bool, editingText: Bool, shift: Bool = false) -> Bool {
        guard focused, !editingText, let shot = currentShot else { return false }
        switch key {
        case .backward: playhead -= shift ? 24 : 1
        case .forward: playhead += shift ? 24 : 1
        case .home: playhead = 0
        case .end: playhead = shot.frameCount - 1
        case .delete:
            guard !isReadOnly else { return false }
            let markID: MarkID
            switch selection {
            case let .actorMark(_, id), let .cameraMark(id): markID = id
            default: return false
            }
            run(.deleteMarks(shot.id, [markID]))
        }
        isPlaying = false
        return true
    }

    /// Blockout store.ts restarts a shot when Play is pressed at its end.
    func toggleShotsPlayback(editingText: Bool = false) {
        guard !editingText, let shot = currentShot else { return }
        if !isPlaying, playhead == shot.frameCount - 1 { playhead = 0 }
        isPlaying.toggle()
    }

    var canAddGuideAtPlayhead: Bool {
        guard let shot = currentShot, !isReadOnly else { return false }
        return playhead > 0 && playhead < shot.frameCount - 1 && !shot.guideFrames.contains(playhead)
    }

    func addGuideAtPlayhead() {
        guard canAddGuideAtPlayhead, let shot = currentShot else { return }
        run(.setGuideFrames(shot.id, Array(Set(shot.guideFrames + [playhead])).sorted()))
    }
}
