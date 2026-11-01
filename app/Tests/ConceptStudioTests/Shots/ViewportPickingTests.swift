import AppKit
@testable import ConceptStudio
import Foundation
import PrevisCore
import SwiftUI
import Testing

@MainActor
struct ViewportPickingTests {
    @Test
    func pickingAtEachEntityProjectedCentreInTwoPersonWalkSelectsThatEntity() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let frame = try #require(store.frame)
        #expect(frame.entities.count >= 2)

        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        for entity in frame.entities {
            let centre = Vec3(
                (entity.bounds.min.x + entity.bounds.max.x) * 0.5,
                (entity.bounds.min.y + entity.bounds.max.y) * 0.5,
                (entity.bounds.min.z + entity.bounds.max.z) * 0.5
            )
            let projected = try #require(camera.project(centre, size: size))
            let pickedID = ViewportPicking.pickEntity(
                at: projected,
                in: frame,
                camera: camera,
                size: size
            )
            #expect(pickedID == entity.id)
            ViewportPicking.handleClick(at: projected, in: store, camera: camera, size: size)
            #expect(store.selection == .entities([entity.id]))
        }

        let firstCentre = entityBoundsCentre(frame.entities[0])
        let secondCentre = entityBoundsCentre(frame.entities[1])
        let firstPixel = try #require(camera.project(firstCentre, size: size))
        let secondPixel = try #require(camera.project(secondCentre, size: size))
        ViewportPicking.handleClick(at: firstPixel, in: store, camera: camera, size: size)
        ViewportPicking.handleClick(
            at: secondPixel,
            in: store,
            camera: camera,
            size: size,
            shiftPressed: true
        )
        #expect(store.selection == .entities([frame.entities[0].id, frame.entities[1].id]))

        ViewportPicking.handleClick(
            at: secondPixel,
            in: store,
            camera: camera,
            size: size,
            shiftPressed: true
        )
        #expect(store.selection == .entities([frame.entities[0].id, frame.entities[1].id]))

        let skyCorner = Point2(x: 8, y: 8)
        ViewportPicking.handleClick(at: skyCorner, in: store, camera: camera, size: size, shiftPressed: true)
        #expect(store.selection == .entities([frame.entities[0].id, frame.entities[1].id]))

        ViewportPicking.handleClick(at: skyCorner, in: store, camera: camera, size: size, shiftPressed: false)
        #expect(store.selection == .none)
    }

    @Test
    func groundIntersectionHitsProjectedGroundPointsFromAboveAndBelowAndRejectsAwayOrParallelRays() throws {
        let size = PixelSize(width: 640, height: 480)
        let desiredGroundPoint = Vec3(1.25, 0.0, -0.75)

        let aboveCamera = EditorCamera.defaultView
        #expect(aboveCamera.position.y > 0)
        let abovePixel = try #require(aboveCamera.project(desiredGroundPoint, size: size))
        let aboveHit = try #require(ViewportPicking.intersectGround(at: abovePixel, camera: aboveCamera, size: size))
        #expect(distance(aboveHit, desiredGroundPoint) < 0.01)

        var belowCamera = EditorCamera.defaultView
        belowCamera.pitch = 0.65
        #expect(belowCamera.position.y < 0)
        let belowPixel = try #require(belowCamera.project(desiredGroundPoint, size: size))
        let belowHit = try #require(ViewportPicking.intersectGround(at: belowPixel, camera: belowCamera, size: size))
        #expect(distance(belowHit, desiredGroundPoint) < 0.01)

        let awayFromGroundCamera = EditorCamera(
            target: Vec3(0, 4.0, 0),
            distance: 5.0,
            yaw: 0,
            pitch: 0.45
        )
        #expect(awayFromGroundCamera.position.y > 0)
        let centrePixel = Point2(x: 320, y: 240)
        #expect(ViewportPicking.intersectGround(at: centrePixel, camera: awayFromGroundCamera, size: size) == nil)

        let parallelCamera = EditorCamera(target: Vec3(0, 2.0, 0), distance: 5.0, yaw: 0, pitch: 0)
        #expect(ViewportPicking.intersectGround(at: centrePixel, camera: parallelCamera, size: size) == nil)
    }

    @Test
    func placeToolPlacesEntityOnGroundWithinOneCentimetreAndRespectsOptionAndEscape() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        store.chooseAssetForPlacement("person.man")
        #expect(store.tool == .place(assetID: "person.man"))

        let targetGroundA = Vec3(-0.85, 0.0, 1.40)
        let pixelA = try #require(camera.project(targetGroundA, size: size))
        ViewportPicking.handleClick(
            at: pixelA,
            in: store,
            camera: camera,
            size: size,
            optionPressed: true
        )
        #expect(store.tool == .place(assetID: "person.man"))
        let placedIDA: EntityID = switch store.selection {
        case let .entities(ids): try #require(ids.first)
        default: Issue.record("Expected placed entity to be selected"); throw CancellationError()
        }
        let placedA = try #require(store.currentScene?.entities.first(where: { $0.id == placedIDA }))
        #expect(distance(placedA.placement.position, targetGroundA) < 0.01)
        #expect(placedA.name == "Man 2")

        let targetGroundB = Vec3(0.75, 0.0, 1.25)
        let pixelB = try #require(camera.project(targetGroundB, size: size))
        ViewportPicking.handleClick(
            at: pixelB,
            in: store,
            camera: camera,
            size: size,
            optionPressed: false
        )
        #expect(store.tool == .select)
        let placedIDB: EntityID = switch store.selection {
        case let .entities(ids): try #require(ids.first)
        default: Issue.record("Expected second placed entity to be selected"); throw CancellationError()
        }
        let placedB = try #require(store.currentScene?.entities.first(where: { $0.id == placedIDB }))
        #expect(distance(placedB.placement.position, targetGroundB) < 0.01)
        #expect(placedB.name == "Man 3")

        store.chooseAssetForPlacement("furniture.chair")
        #expect(store.tool == .place(assetID: "furniture.chair"))
        let handledEsc = ViewportPicking.handleKeyDown(
            charactersIgnoringModifiers: "\u{1B}",
            keyCode: 53,
            in: store
        )
        #expect(handledEsc)
        #expect(store.tool == .select)
    }

    @Test
    func dropMarksToolProducesActorMarkAndSubjectAimedCameraMarkAtPlayheadTime() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)

        store.playhead = 9
        let expectedTime = FrameGrid.time(ofFrame: 9)
        store.selection = .entities(["ent_000000000001"])

        let handledM = ViewportPicking.handleKeyDown(
            charactersIgnoringModifiers: "m",
            keyCode: 46,
            in: store
        )
        #expect(handledM)
        #expect(store.tool == .dropMarks)

        let actorGroundTarget = Vec3(-0.6, 0.0, 1.1)
        let actorPixel = try #require(camera.project(actorGroundTarget, size: size))
        ViewportPicking.handleClick(at: actorPixel, in: store, camera: camera, size: size)

        let take = try #require(store.currentScene?.blocking.first)
        let manTrack = try #require(take.tracks.first(where: { $0.entityID == "ent_000000000001" }))
        let droppedActorMark = try #require(manTrack.marks.first(where: { abs($0.time - expectedTime) < 1e-9 }))
        #expect(droppedActorMark.gait == .walk)
        #expect(droppedActorMark.hold == 0)
        #expect(droppedActorMark.easeIn == 0.25)
        #expect(droppedActorMark.easeOut == 0.25)
        #expect(distance(droppedActorMark.position, actorGroundTarget) < 0.01)

        let shotID = try #require(store.currentShotID)
        store.run(.setTracking(shotID, ["ent_000000000002"]))
        store.selection = .camera
        store.playhead = 12
        let camTime = FrameGrid.time(ofFrame: 12)
        let subjectFrame = try #require(store.frame?.entities.first(where: { $0.id == "ent_000000000002" }))
        let subjectHeight = (catalog.asset(subjectFrame.assetID)?.height ?? 1.7) * 1.0

        let camGroundTarget = Vec3(1.1, 0.0, 2.2)
        let camPixel = try #require(camera.project(camGroundTarget, size: size))
        let markID = try #require(ViewportPicking.dropMark(at: camPixel, in: store, camera: camera, size: size))
        let droppedCamMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == markID }))
        #expect(abs(droppedCamMark.time - camTime) < 1e-9)
        #expect(droppedCamMark.hold == 0)
        #expect(droppedCamMark.easeIn == 0.3)
        #expect(droppedCamMark.easeOut == 0.3)
        #expect(droppedCamMark.roll == 0)
        let camHorizDist = hypot(
            droppedCamMark.position.x - camGroundTarget.x,
            droppedCamMark.position.z - camGroundTarget.z
        )
        #expect(camHorizDist < 0.01)

        let dx = subjectFrame.position.x - droppedCamMark.position.x
        let dy = (subjectFrame.position.y + subjectHeight * 0.8) - droppedCamMark.position.y
        let dz = subjectFrame.position.z - droppedCamMark.position.z
        let expectedPan = atan2(-dx, -dz)
        let expectedTilt = atan2(dy, max(hypot(dx, dz), 1e-4))
        #expect(abs(droppedCamMark.pan - expectedPan) < 1e-6)
        #expect(abs(droppedCamMark.tilt - expectedTilt) < 1e-6)

        store.run(.setCameraRig(shotID, sensor: .super35, rig: .carMount, intensity: 0))
        store.run(.setMount(shotID, "ent_000000000001"))
        store.playhead = 6
        let mountFrame = try #require(store.frame?.entities.first(where: { $0.id == "ent_000000000001" }))
        let mountedMarkID = try #require(ViewportPicking.dropMark(at: camPixel, in: store, camera: camera, size: size))
        let mountedMark = try #require(store.currentShot?.camera.marks.first(where: { $0.id == mountedMarkID }))
        let mdx = camGroundTarget.x - mountFrame.position.x
        let mdz = camGroundTarget.z - mountFrame.position.z
        let expectedLocalX = mdx * cos(mountFrame.heading) - mdz * sin(mountFrame.heading)
        let expectedLocalZ = mdx * sin(mountFrame.heading) + mdz * cos(mountFrame.heading)
        #expect(hypot(mountedMark.position.x - expectedLocalX, mountedMark.position.z - expectedLocalZ) < 0.01)
    }

    @Test
    func readOnlyStoreAllowsSelectionWhileBlockingPlaceAndDropMarks() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil, readOnly: true)
        let camera = EditorCamera.defaultView
        let size = PixelSize(width: 640, height: 480)
        let frame = try #require(store.frame)
        let initialEntityCount = try #require(store.currentScene?.entities.count)

        #expect(!ViewportPicking.handleKeyDown(charactersIgnoringModifiers: "m", keyCode: 46, in: store))
        #expect(store.tool == .select)

        store.tool = .place(assetID: "person.man")
        let manCentre = entityBoundsCentre(frame.entities[0])
        let manPixel = try #require(camera.project(manCentre, size: size))
        ViewportPicking.handleClick(at: manPixel, in: store, camera: camera, size: size)
        #expect(store.currentScene?.entities.count == initialEntityCount)
        #expect(store.selection == .entities([frame.entities[0].id]))

        store.tool = .dropMarks
        let markCountBefore = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.count)
        let groundPixel = try #require(camera.project(Vec3(0, 0, 1.0), size: size))
        #expect(ViewportPicking.dropMark(at: groundPixel, in: store, camera: camera, size: size) == nil)
        let markCountAfter = try #require(store.currentScene?.blocking.first?.tracks.first?.marks.count)
        #expect(markCountAfter == markCountBefore)
    }

    @Test
    func nearestForwardHitWinsOverOccludedEntityAndSupportsAllPartShapes() {
        let camera = EditorCamera(target: Vec3(0, 1, 0), distance: 6.0, yaw: 0, pitch: 0)
        let size = PixelSize(width: 640, height: 480)
        let centrePixel = Point2(x: 320, y: 240)

        let nearTransform = makeTransform(position: Vec3(0, 1, 2.0), yaw: 0.4, scale: 1.0)
        let farTransform = makeTransform(position: Vec3(0, 1, -1.5), yaw: 0.0, scale: 1.5)
        let nearEntity = EntityFrame(
            id: "ent_near",
            assetID: "prim.box",
            name: "Near",
            isActor: false,
            position: Vec3(0, 1, 2.0),
            heading: 0.4,
            gait: .stand,
            speed: 0,
            distanceTravelled: 0,
            parts: [
                PosedPart(
                    id: "p1",
                    shape: .cylinder(radius: 0.4, height: 1.2),
                    transform: nearTransform,
                    color: RGB(hex: "#ffffff")
                ),
            ],
            bounds: Box3(min: Vec3(-0.5, 0.4, 1.5), max: Vec3(0.5, 1.6, 2.5))
        )
        let farEntity = EntityFrame(
            id: "ent_far",
            assetID: "prim.box",
            name: "Far",
            isActor: false,
            position: Vec3(0, 1, -1.5),
            heading: 0,
            gait: .stand,
            speed: 0,
            distanceTravelled: 0,
            parts: [
                PosedPart(
                    id: "p2",
                    shape: .sphere(radius: 0.8),
                    transform: farTransform,
                    color: RGB(hex: "#ffffff")
                ),
            ],
            bounds: Box3(min: Vec3(-1.2, -0.2, -2.7), max: Vec3(1.2, 2.2, -0.3))
        )
        let frame = SceneFrame(
            index: 0,
            time: 0,
            canvas: .portrait,
            camera: camera.cameraFrame(for: size),
            entities: [farEntity, nearEntity]
        )
        #expect(ViewportPicking.pickEntity(at: centrePixel, in: frame, camera: camera, size: size) == "ent_near")
    }

    private func makeTransform(position: Vec3, yaw: Double, scale: Double) -> Mat4 {
        var mat = Mat4.identity
        let c = cos(yaw) * scale
        let s = sin(yaw) * scale
        mat.m[0] = c
        mat.m[2] = -s
        mat.m[5] = scale
        mat.m[8] = s
        mat.m[10] = c
        mat.m[12] = position.x
        mat.m[13] = position.y
        mat.m[14] = position.z
        return mat
    }
}

@MainActor
extension ViewportPickingTests {
    @Test
    func hostedShotsViewportRoutesClickVsDragAndKeyboardToolShortcuts() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let viewportSize = CGSize(width: 640, height: 480)
        let host = NSHostingView(
            rootView: ShotsViewport(store: store)
                .frame(width: viewportSize.width, height: viewportSize.height)
        )
        host.frame = CGRect(origin: .zero, size: viewportSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewportSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let overlayView = try #require(findScrollCapturingView(in: host))
        let session = try #require(overlayView.session)
        let pixelSize = PixelSize(width: 640, height: 480)
        let manEntity = try #require(store.frame?.entities.first)
        let projectedMan = try #require(session.editorCamera.project(entityBoundsCentre(manEntity), size: pixelSize))
        let windowClickPoint = overlayView.convert(CGPoint(x: projectedMan.x, y: projectedMan.y), to: nil)

        sendMouse(type: .leftMouseDown, at: windowClickPoint, in: window, to: overlayView)
        sendMouse(type: .leftMouseUp, at: windowClickPoint, in: window, to: overlayView)
        #expect(store.selection == .entities([manEntity.id]))

        let yawBeforeDrag = session.editorCamera.yaw
        let emptyWinPoint = overlayView.convert(CGPoint(x: 40, y: 40), to: nil)
        let draggedWinPoint = overlayView.convert(CGPoint(x: 90, y: 55), to: nil)
        sendMouse(type: .leftMouseDown, at: emptyWinPoint, in: window, to: overlayView)
        sendMouse(type: .leftMouseDragged, at: draggedWinPoint, in: window, to: overlayView)
        sendMouse(type: .leftMouseUp, at: draggedWinPoint, in: window, to: overlayView)
        #expect(store.selection == .entities([manEntity.id]))
        #expect(abs(session.editorCamera.yaw - yawBeforeDrag) > 0.01)

        sendKey(characters: "m", keyCode: 46, in: window, to: overlayView)
        #expect(store.tool == .dropMarks)
        sendKey(characters: "\u{1B}", keyCode: 53, in: window, to: overlayView)
        #expect(store.tool == .select)
    }

    @Test
    func subThresholdMouseJitterDoesNotOrbitCameraBeforeClickPlacementWhileTrueDragOrbitsWithoutPlacing() throws {
        let catalog = try ContentCatalog.bundled()
        let document = ShotsSamples.twoPersonWalk(small: true)
        let store = ShotsStore(catalog: catalog, document: document, saveURL: nil)
        let viewportSize = CGSize(width: 640, height: 480)
        let host = NSHostingView(
            rootView: ShotsViewport(store: store)
                .frame(width: viewportSize.width, height: viewportSize.height)
        )
        host.frame = CGRect(origin: .zero, size: viewportSize)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewportSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        let overlayView = try #require(findScrollCapturingView(in: host))
        let session = try #require(overlayView.session)
        let pixelSize = PixelSize(width: 640, height: 480)
        let initialCamera = session.editorCamera
        let startPixel = try #require(initialCamera.project(Vec3(0, 0, 1.4), size: pixelSize))

        // 1. 0-point exact click control: camera unchanged, places at exact ray-ground hit (< 1 cm).
        store.chooseAssetForPlacement("person.man")
        let count0 = try #require(store.currentScene?.entities.count)
        let winStart = overlayView.convert(CGPoint(x: startPixel.x, y: startPixel.y), to: nil)
        sendMouse(type: .leftMouseDown, at: winStart, in: window, to: overlayView)
        sendMouse(type: .leftMouseUp, at: winStart, in: window, to: overlayView)
        #expect(session.editorCamera == initialCamera)
        #expect(store.currentScene?.entities.count == count0 + 1)
        let placed0 = try #require(store.currentScene?.entities.last)
        let expected0 = try #require(ViewportPicking.intersectGround(
            at: startPixel,
            camera: initialCamera,
            size: pixelSize
        ))
        #expect(distance(placed0.placement.position, expected0) < 0.01)

        // 2. 2-point (< 3 pt) sub-threshold jitter regression: camera must remain unchanged and placement < 1 cm.
        store.chooseAssetForPlacement("person.man")
        let count1 = try #require(store.currentScene?.entities.count)
        let releasePixel2 = Point2(x: startPixel.x + 2.0, y: startPixel.y)
        let winRelease2 = overlayView.convert(CGPoint(x: releasePixel2.x, y: releasePixel2.y), to: nil)
        sendMouse(type: .leftMouseDown, at: winStart, in: window, to: overlayView)
        sendMouse(type: .leftMouseDragged, at: winRelease2, in: window, to: overlayView)
        sendMouse(type: .leftMouseUp, at: winRelease2, in: window, to: overlayView)
        #expect(session.editorCamera == initialCamera)
        #expect(store.currentScene?.entities.count == count1 + 1)
        let placed2 = try #require(store.currentScene?.entities.last)
        let expected2 = try #require(ViewportPicking.intersectGround(
            at: releasePixel2,
            camera: initialCamera,
            size: pixelSize
        ))
        #expect(distance(placed2.placement.position, expected2) < 0.01)

        // 3. 8-point (> 3 pt) true drag control: orbits camera and does NOT place an entity.
        store.chooseAssetForPlacement("person.man")
        let count2 = try #require(store.currentScene?.entities.count)
        let winDrag8 = overlayView.convert(CGPoint(x: startPixel.x + 8.0, y: startPixel.y), to: nil)
        sendMouse(type: .leftMouseDown, at: winStart, in: window, to: overlayView)
        sendMouse(type: .leftMouseDragged, at: winDrag8, in: window, to: overlayView)
        sendMouse(type: .leftMouseUp, at: winDrag8, in: window, to: overlayView)
        #expect(abs(session.editorCamera.yaw - initialCamera.yaw) > 0.05)
        #expect(store.currentScene?.entities.count == count2)
        #expect(store.tool == .place(assetID: "person.man"))
    }

    private func findScrollCapturingView(in root: NSView) -> ViewportScrollWheelOverlay.ScrollCapturingView? {
        if let match = root as? ViewportScrollWheelOverlay.ScrollCapturingView { return match }
        for child in root.subviews {
            if let match = findScrollCapturingView(in: child) { return match }
        }
        return nil
    }

    private func sendMouse(
        type: NSEvent.EventType,
        at windowPoint: NSPoint,
        in window: NSWindow,
        to view: ViewportScrollWheelOverlay.ScrollCapturingView
    ) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    private func sendKey(
        characters: String,
        keyCode: UInt16,
        in window: NSWindow,
        to view: ViewportScrollWheelOverlay.ScrollCapturingView
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        view.keyDown(with: event)
    }

    private func entityBoundsCentre(_ entity: EntityFrame) -> Vec3 {
        Vec3(
            (entity.bounds.min.x + entity.bounds.max.x) * 0.5,
            (entity.bounds.min.y + entity.bounds.max.y) * 0.5,
            (entity.bounds.min.z + entity.bounds.max.z) * 0.5
        )
    }

    private func distance(_ a: Vec3, _ b: Vec3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
