// Adapted from Blockout src/renderer/panels/Timeline.tsx at 3f2d0564, Apache-2.0, by Sam Wasserman.
// Changes: native SwiftUI, frame snapping, typed previews/commands and CONTRACTS focus ownership.
import AppKit
import PrevisCore
import SwiftUI

/// Native version of Blockout's Timeline.tsx: camera first, local drag preview, one command on release.
struct ShotsTimelineView: View {
    @Bindable var store: ShotsStore
    @FocusState private var focused: Bool
    @State private var drag = ShotsTimelineDragTransaction()
    @GestureState private var pointerDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            transport
            if let shot = store.currentShot, let scene = store.currentScene {
                GeometryReader { proxy in
                    let geometry = ShotsTimelineGeometry(
                        frameCount: shot.frameCount,
                        width: max(1, proxy.size.width - 184)
                    )
                    VStack(spacing: 4) {
                        ruler(shot: shot, geometry: geometry)
                        ScrollView {
                            VStack(spacing: 4) {
                                lane(
                                    name: "Camera",
                                    marks: shot.camera.marks.map { .camera(shot.id, $0) },
                                    geometry: geometry
                                )
                                if let take = scene.blocking.first(where: { $0.id == shot.blockingTakeID }) {
                                    ForEach(take.tracks, id: \.entityID) { track in
                                        if let entity = scene.entities.first(where: { $0.id == track.entityID }) {
                                            let label = entity.label?.text ?? ""
                                            lane(
                                                name: label.isEmpty ? entity.name : label,
                                                spokenName: entity.name,
                                                marks: track.marks.map { .actor(shot.id, entity.id, $0) },
                                                geometry: geometry
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Select a shot to see its marks.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .focusable().focused($focused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shots timeline")
        .help(ShotsAccessibility.timelineHint)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .home, .end, .delete]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            let key: ShotsTimelineKey = switch press.key {
            case .leftArrow: .backward
            case .rightArrow: .forward
            case .home: .home
            case .end: .end
            default: .delete
            }
            return store.navigateTimeline(
                key, focused: focused, editingText: Self.editingText,
                shift: press.modifiers.contains(.shift)
            ) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard drag.isActive else { return .ignored }
            cancelDrag()
            return .handled
        }
        .task(id: playbackTaskID) {
            if store.isPlayingScene {
                await playScene()
            } else {
                await play()
            }
        }
        .onChange(of: store.currentShotID) { cancelDrag() }
        .onChange(of: pointerDragging) {
            if !pointerDragging {
                cancelDrag()
                drag.reset()
            }
        }
        .onDisappear {
            cancelDrag()
            store.isPlaying = false
        }
    }

    private var transport: some View {
        let seconds = FrameGrid.time(ofFrame: store.playhead)
        let count = store.currentShot?.frameCount ?? 0
        return HStack(spacing: 12) {
            Text("Timeline").font(.headline).accessibilityAddTraits(.isHeader)
            Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
                store.toggleShotsPlayback()
            }
            .disabled(store.currentShot == nil || store.isPlayingScene)
            Button(store.isPlayingScene ? "Pause scene" : "Play scene", systemImage: "film") {
                if store.isPlayingScene {
                    store.isPlaying = false
                } else {
                    store.isPlayingScene = true
                    store.isPlaying = true
                }
            }
            .disabled((store.currentScene?.shots.count ?? 0) < 2)
            Text("Frame \(store.playhead) of \(count) · \(seconds, specifier: "%.2f") s")
                .monospacedDigit().font(.callout)
            Spacer(minLength: 4)
            Button("Add guide frame here", systemImage: "bookmark") { store.addGuideAtPlayhead() }
                .disabled(!store.canAddGuideAtPlayhead)
        }
    }

    private func ruler(shot: Shot, geometry: ShotsTimelineGeometry) -> some View {
        HStack(spacing: 8) {
            Text("24 fps").font(.caption).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.05))
                ForEach(Array(stride(from: 0, to: shot.frameCount, by: 24)), id: \.self) { frame in
                    // Starts just right of its tick, clear of the playhead line drawn on it.
                    let tick = geometry.position(atTime: FrameGrid.time(ofFrame: frame))
                    Text("\(frame) · \(frame / 24)s").font(.caption2).monospacedDigit()
                        .offset(x: min(geometry.width - 44, tick + 4))
                }
                ForEach(shot.guideFrames, id: \.self) { frame in
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange).font(.caption2)
                        .offset(x: max(0, geometry.position(atTime: FrameGrid.time(ofFrame: frame)) - 4), y: 14)
                        .accessibilityLabel("Guide at frame \(frame)")
                }
                playhead(geometry: geometry)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                focused = true
                store.isPlaying = false
                store.playhead = geometry.frame(atPosition: value.location.x)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playhead")
            .accessibilityValue("Frame \(store.playhead) of \(shot.frameCount)")
            .accessibilityAdjustableAction { direction in
                _ = store.navigateTimeline(
                    direction == .increment ? .forward : .backward,
                    focused: true,
                    editingText: false
                )
            }
        }
    }

    /// `name` is the row's visible tag (an entity's label when it has one); VoiceOver always hears `spokenName`.
    private func lane(
        name: String, spokenName: String? = nil, marks: [ShotsTimelineDrag.Mark], geometry: ShotsTimelineGeometry
    ) -> some View {
        let spokenName = spokenName ?? name
        return HStack(spacing: 8) {
            Text(name).font(.caption).lineLimit(1).help(spokenName).frame(width: 112, alignment: .leading)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.04))
                ForEach(marks, id: \.id) { mark in pill(mark, name: spokenName, geometry: geometry) }
                playhead(geometry: geometry).allowsHitTesting(false)
            }
            .frame(height: 30)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(spokenName) marks")
    }

    private func pill(_ mark: ShotsTimelineDrag.Mark, name: String, geometry: ShotsTimelineGeometry) -> some View {
        let start = geometry.position(atTime: mark.time)
        let holdWidth = geometry.position(atTime: mark.time + mark.hold) - start
        let label = ShotsAccessibility.markLabel(lane: name, time: mark.time, gait: mark.gait)
        return HStack(spacing: 0) {
            Text("\(FrameGrid.frame(atTime: mark.time))")
                .font(.caption2).monospacedDigit().padding(.horizontal, 5)
                .frame(width: max(38, holdWidth - 8), height: 24, alignment: .leading)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { focused = true; store.selection = mark.selection }
                .gesture(markGesture(mark, mode: .move, geometry: geometry))
            Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 8, height: 24)
                .contentShape(Rectangle())
                .gesture(markGesture(mark, mode: .stretch, geometry: geometry))
                .help("Drag to stretch the hold")
        }
        .background(store.selection == mark.selection ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.3)))
        .offset(x: start)
        // Help only: the label already names the mark, and VoiceOver reads both.
        .help("Click to edit this mark in the inspector, or drag to change its time.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("Hold \(ShotsAccessibility.seconds(mark.hold))")
        .accessibilityAddTraits(store.selection == mark.selection ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { focused = true; store.selection = mark.selection }
    }

    private func markGesture(
        _ mark: ShotsTimelineDrag.Mark,
        mode: ShotsTimelineDrag.Mode,
        geometry: ShotsTimelineGeometry
    ) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($pointerDragging) { _, active, _ in active = true }
            .onChanged { value in
                guard !store.isReadOnly, let command = drag.update(
                    mark: mark, mode: mode, geometry: geometry, delta: value.translation.width
                ) else { return }
                focused = true
                store.isPlaying = false
                store.selection = mark.selection
                store.preview = [command]
                if mode == .move {
                    switch command {
                    case let .updateActorMark(_, _, mark): store.playhead = FrameGrid.frame(atTime: mark.time)
                    case let .updateCameraMark(_, mark): store.playhead = FrameGrid.frame(atTime: mark.time)
                    default: break
                    }
                }
            }
            .onEnded { value in
                if let command = drag.finish(delta: value.translation.width) { store.run(command) }
            }
    }

    private func playhead(geometry: ShotsTimelineGeometry) -> some View {
        Rectangle().fill(Color.accentColor).frame(width: 2)
            .offset(x: geometry.position(atTime: FrameGrid.time(ofFrame: store.playhead)))
    }

    private func cancelDrag() {
        if drag.isActive { store.preview = []; drag.cancel() }
    }

    private var playbackTaskID: String? {
        guard store.isPlaying else { return nil }
        if store.isPlayingScene, let scene = store.currentScene {
            return "scene/\(scene.id)/\(scene.revision)"
        }
        return "shot/\(store.currentShotID ?? "")/\(store.currentShot?.frameCount ?? 0)"
    }

    @MainActor private func playScene() async {
        guard let scene = store.currentScene, let list = try? SceneCutList(scene: scene), list.frameCount > 0 else {
            store.isPlaying = false
            return
        }
        let start = ContinuousClock.now
        do {
            while store.isPlayingScene, !Task.isCancelled, store.currentSceneID == scene.id {
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let frame = Int(seconds * Double(FrameGrid.fps))
                let displayed = min(frame, list.frameCount - 1)
                if let cut = list.cut(at: displayed) {
                    if store.currentShotID != cut.shotID {
                        store.selection = .none
                        store.currentShotID = cut.shotID
                    }
                    store.playhead = displayed - cut.startFrame
                }
                if frame >= list.frameCount {
                    store.isPlaying = false
                    return
                }
                try await Task.sleep(for: .nanoseconds(1_000_000_000 / 24))
            }
        } catch is CancellationError {} catch { store.onError?(error.localizedDescription) }
    }

    @MainActor private func play() async {
        guard store.isPlaying, let shot = store.currentShot, shot.frameCount > 0 else { return }
        let start = ContinuousClock.now, first = store.playhead
        do {
            while store.isPlaying, !Task.isCancelled, store.currentShotID == shot.id {
                try await Task.sleep(for: .nanoseconds(1_000_000_000 / 24))
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                store.playhead = ShotsTimelinePlayback.frame(
                    startingAt: first,
                    count: shot.frameCount,
                    elapsed: seconds
                )
            }
        } catch is CancellationError {} catch { store.onError?(error.localizedDescription) }
    }

    static var editingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }
}

private extension ShotsTimelineDrag.Mark {
    var id: MarkID {
        switch self {
        case let .actor(_, _, mark): mark.id
        case let .camera(_, mark): mark.id
        }
    }

    var time: Double {
        switch self {
        case let .actor(_, _, mark): mark.time
        case let .camera(_, mark): mark.time
        }
    }

    var hold: Double {
        switch self {
        case let .actor(_, _, mark): mark.hold
        case let .camera(_, mark): mark.hold
        }
    }

    var gait: Gait? {
        switch self {
        case let .actor(_, _, mark): mark.gait
        case .camera: nil
        }
    }

    var selection: ShotsSelection {
        switch self {
        case let .actor(_, entity, mark): .actorMark(entity, mark.id)
        case let .camera(_, mark): .cameraMark(mark.id)
        }
    }
}
