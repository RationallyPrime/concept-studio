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
        .contentShape(Rectangle())
        .focusable().focused($focused)
        .accessibilityLabel("Shots timeline")
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
        .task(id: store.isPlaying ? "\(store.currentShotID ?? "")/\(store.currentShot?.frameCount ?? 0)" : nil) {
            await play()
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
            Text("Timeline").font(.headline)
            Button(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
                store.toggleShotsPlayback()
            }
            .disabled(store.currentShot == nil)
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
                    Text("\(frame) · \(frame / 24)s").font(.caption2).monospacedDigit()
                        .offset(x: min(geometry.width - 44, geometry.position(atTime: FrameGrid.time(ofFrame: frame))))
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

    private func lane(name: String, marks: [ShotsTimelineDrag.Mark], geometry: ShotsTimelineGeometry) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).lineLimit(1).help(name).frame(width: 112, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.04))
                ForEach(marks, id: \.id) { mark in pill(mark, name: name, geometry: geometry) }
                playhead(geometry: geometry).allowsHitTesting(false)
            }
            .frame(height: 30)
            .clipped()
        }
    }

    private func pill(_ mark: ShotsTimelineDrag.Mark, name: String, geometry: ShotsTimelineGeometry) -> some View {
        let start = geometry.position(atTime: mark.time)
        let holdWidth = geometry.position(atTime: mark.time + mark.hold) - start
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
        .help("\(name), \(mark.gait), \(mark.time.formatted(.number.precision(.fractionLength(2)))) seconds")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(mark.gait), mark at \(mark.time, specifier: "%.2f") seconds")
        .accessibilityValue("Hold \(mark.hold, specifier: "%.2f") seconds")
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
                store.preview = command
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
        if drag.isActive { store.preview = nil; drag.cancel() }
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

    var gait: String {
        switch self {
        case let .actor(_, _, mark): mark.gait.rawValue
        case .camera: "camera"
        }
    }

    var selection: ShotsSelection {
        switch self {
        case let .actor(_, entity, mark): .actorMark(entity, mark.id)
        case let .camera(_, mark): .cameraMark(mark.id)
        }
    }
}
