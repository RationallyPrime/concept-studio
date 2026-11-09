import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import RealityKit
import ShotsMedia
import SwiftUI
import Testing

/// CONTRACTS section 10, Lane D's budget (release build, Apple silicon): viewport orbit at 60 fps with 20 entities,
/// scrubbing and playback at 24 fps. Runs only with `SHOTS_TIMING=1`; CI never sets it, and a debug-build number is
/// not the budget. Run from `app/`: `SHOTS_TIMING=1 swift test -c release --filter ViewportTiming`.
///
/// What this measures, and what it cannot: `swift test` is not a running, active application, so RealityKit never
/// draws a `RealityView` frame here (its scene receives no `SceneEvents.Update`) and an on-screen frame rate can't
/// be read headlessly. Each frame is therefore measured as the two halves the app pays for it:
/// - **update:** the main-actor work one input step causes inside Lane C's workspace layout. For orbit that is a real
///   `mouseDragged` event through the viewport's AppKit input view, the SwiftUI pass it triggers, and one full
///   `ViewportLiveSession.sync`, which is what `RealityView`'s update closure runs. For playback it is one playhead
///   step, the SwiftUI pass and one full sync.
/// - **draw:** a RealityKit render of the same 20-entity stage, with the editor overlay, from the editor camera at the
///   viewport's size in Retina backing pixels (twice its points), through the export renderer
///   (`ShotFrameRenderer`), awaited, including its read-back into a `CGImage`. The live view draws on RealityKit's
///   render thread without a read-back, so this overstates what a frame costs.
/// The frame time reported is update + draw, a conservative stand-in for the on-screen frame. Playback in the shot
/// camera view is measured as well: one playhead step, then `ShotCameraView`'s coalesced render of the canvas.
@Suite("ViewportTiming", .enabled(if: viewportTimingEnabled))
@MainActor
struct ViewportTimingTests {
    @Test func orbitHoldsSixtyAndPlaybackTwentyFourWithTwentyEntities() async throws {
        let catalog = try ContentCatalog.bundled()
        let store = try ShotsStore(catalog: catalog, document: Self.twentyEntityDocument(), saveURL: nil)
        #expect(store.currentScene?.entities.count == 20)
        #expect(store.frame?.entities.count == 20)
        var workspace = try HostedWorkspace(store: store)
        defer { workspace.close() }
        let session = try workspace.session()
        let size = session.viewportSize
        // Retina backing pixels, a MacBook's, whatever displays this Mac has: the costlier case.
        let drawSize = PixelSize(width: size.width * 2, height: size.height * 2)
        let renderer = try ShotFrameRenderer()
        let look = try PrevisLook(scene: #require(store.currentScene))

        // Warm-up: first meshes, materials and the renderer's pipeline.
        // A selected prop off-centre, so the selection box and handles are live but the orbit press misses them.
        store.selection = .entities(["extra_prop_7"])
        let document = store.document
        workspace.settle()
        for _ in 0 ..< 3 {
            _ = try await draw(session: session, store: store, renderer: renderer, look: look, size: drawSize)
        }

        var orbitUpdate: [Double] = [], orbitDraw: [Double] = []
        let clock = ContinuousClock()
        for step in 0 ..< 120 {
            let start = clock.now
            try workspace.orbit(by: CGSize(width: step.isMultiple(of: 2) ? 6 : 5, height: 1))
            workspace.settle()
            session.sync(with: store, frame: store.frame, size: size)
            orbitUpdate.append(milliseconds(clock.now - start))
            let drawn = try await draw(session: session, store: store, renderer: renderer, look: look, size: drawSize)
            orbitDraw.append(drawn)
        }
        try workspace.endOrbit()
        #expect(store.document == document && store.preview == nil, "the orbit press must not grab a handle")

        // Playback with a walking actor selected: its selection box is rebuilt every frame, the costliest case left.
        store.selection = .entities(["ent_000000000001"])
        workspace.settle()
        var playUpdate: [Double] = [], playDraw: [Double] = []
        let frameCount = try #require(store.currentShot?.frameCount)
        for index in 0 ..< frameCount {
            let start = clock.now
            store.playhead = index
            workspace.settle()
            session.sync(with: store, frame: store.frame, size: size)
            playUpdate.append(milliseconds(clock.now - start))
            let drawn = try await draw(session: session, store: store, renderer: renderer, look: look, size: drawSize)
            playDraw.append(drawn)
        }
        let lookThrough = try await lookThroughPlayback(store: store, frameCount: frameCount)

        let orbit = zip(orbitUpdate, orbitDraw).map(+), playback = zip(playUpdate, playDraw).map(+)
        print(
            "TIMING viewport \(size.width) × \(size.height) pt, drawn at \(drawSize.width) × \(drawSize.height) px,"
                + " 20 entities, release=\(!isDebugBuild)"
        )
        print("TIMING orbit update \(summary(orbitUpdate)); draw \(summary(orbitDraw)); frame \(summary(orbit))")
        print("TIMING playback update \(summary(playUpdate)); draw \(summary(playDraw)); frame \(summary(playback))")
        print("TIMING look-through playback (step + render of the 640 × 1152 canvas) \(summary(lookThrough))")
        #expect(percentile(lookThrough, 0.95) < 1000.0 / 24.0, "look-through p95 \(percentile(lookThrough, 0.95)) ms")
        #expect(percentile(orbit, 0.95) < 1000.0 / 60.0, "orbit frame p95 \(percentile(orbit, 0.95)) ms")
        #expect(percentile(playback, 0.95) < 1000.0 / 24.0, "playback frame p95 \(percentile(playback, 0.95)) ms")
    }

    /// Each playhead step, then `ShotCameraView`'s render session drawing it, as the shot camera view does in playback.
    private func lookThroughPlayback(store: ShotsStore, frameCount: Int) async throws -> [Double] {
        let preview = ShotCameraPreviewSession()
        preview.requestRender(for: store)
        await preview.waitForIdle()
        var times: [Double] = []
        let clock = ContinuousClock()
        for index in 0 ..< frameCount {
            let start = clock.now
            store.playhead = index
            preview.requestRender(for: store)
            await preview.waitForIdle()
            times.append(milliseconds(clock.now - start))
            #expect(preview.renderedRequest?.frame.index == index && preview.errorMessage == nil)
        }
        return times
    }

    private func draw(
        session: ViewportLiveSession,
        store: ShotsStore,
        renderer: ShotFrameRenderer,
        look: PrevisLook,
        size: PixelSize
    ) async throws -> Double {
        let frame = try #require(store.frame)
        let overlay = session.overlayRoot.clone(recursive: true)
        let clock = ContinuousClock(), start = clock.now
        let camera = session.editorCamera.cameraFrame(for: size)
        _ = try await renderer.image(of: frame, look: look, camera: camera, overlay: overlay, size: size)
        return milliseconds(clock.now - start)
    }
}

private let viewportTimingEnabled = ShotFrameRenderer.isAvailable
    && ProcessInfo.processInfo.environment["SHOTS_SKIP_RENDER"] == nil
    && ProcessInfo.processInfo.environment["SHOTS_TIMING"] == "1"

#if DEBUG
    private let isDebugBuild = true
#else
    private let isDebugBuild = false
#endif

extension ViewportTimingTests {
    /// The full two-person walk (124 frames, 640 × 1152) grown to 20 entities: ten people walking tracks of their
    /// own and ten props.
    static func twentyEntityDocument() throws -> ShotsDocument {
        var document = ShotsSamples.twoPersonWalk()
        var scene = try #require(document.scenes.first)
        let people = scene.entities.filter { $0.assetID.hasPrefix("person.") }
        let tracks = scene.blocking[0].tracks
        for index in 0 ..< 8 {
            var entity = people[index % people.count]
            let offset = Double(index / 2 + 1) * 1.4
            entity.id = "extra_person_\(index)"
            entity.name = "Extra \(index)"
            entity.placement.position.z -= offset
            scene.entities.append(entity)
            if var track = tracks.first(where: { $0.entityID == people[index % people.count].id }) {
                track.entityID = entity.id
                track.marks = track.marks.map { mark in
                    var copy = mark
                    copy.id = "\(entity.id)_\(mark.id)"
                    copy.position.z -= offset
                    return copy
                }
                scene.blocking[0].tracks.append(track)
            }
        }
        let props = [
            "furniture.armchair", "furniture.couch", "furniture.desk", "furniture.lamp",
            "furniture.diningTable", "furniture.stool", "furniture.shelf", "furniture.tv",
        ]
        for (index, assetID) in props.enumerated() {
            scene.entities.append(PrevisEntity(
                id: "extra_prop_\(index)",
                assetID: assetID,
                name: "Prop \(index)",
                placement: Placement(
                    position: Vec3(Double(index % 4) * 1.5 - 2.25, 0, -4 - Double(index / 4) * 1.5),
                    heading: 0,
                    scale: 1
                )
            ))
        }
        document.scenes[0] = scene
        return document
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

private func summary(_ values: [Double]) -> String {
    String(
        format: "median %.2f ms, p95 %.2f ms, max %.2f ms (n=%d)",
        percentile(values, 0.5), percentile(values, 0.95), values.max() ?? .nan, values.count
    )
}
