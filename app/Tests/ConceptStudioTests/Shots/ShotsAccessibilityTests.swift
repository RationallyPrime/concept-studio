@testable import ConceptStudio
import Foundation
import PrevisCore
import ShotsMedia
import Testing

@Suite("Shots accessibility text")
@MainActor
struct ShotsAccessibilityTests {
    @Test func timelinePillsReadTheirEntityTimeAndGait() {
        #expect(ShotsAccessibility
            .markLabel(lane: "Woman", time: 1.5, gait: .walk) == "Woman, mark at 1.50 seconds, walk")
        #expect(ShotsAccessibility.markLabel(lane: "Man", time: 0, gait: .lie) == "Man, mark at 0.00 seconds, lie down")
        #expect(ShotsAccessibility.markLabel(lane: "Camera", time: 2, gait: nil) == "Camera mark at 2.00 seconds")
        #expect(ShotsAccessibility.seconds(1) == "1.00 second")
    }

    @Test func fieldTitlesAreSpokenWithWholeUnitsAndMarkFieldsAreExplained() {
        #expect(ShotsAccessibility.spokenTitle("X (m)") == "X in metres")
        #expect(ShotsAccessibility.spokenTitle("Speed (m/s)") == "Speed in metres per second")
        #expect(ShotsAccessibility.spokenTitle("Focal length (mm)") == "Focal length in millimetres")
        #expect(ShotsAccessibility.spokenTitle("Pan (°)") == "Pan in degrees")
        #expect(ShotsAccessibility.spokenTitle("Hold (s)") == "Hold in seconds")
        #expect(ShotsAccessibility.spokenTitle("Ease in") == "Ease in")
        for title in [
            "Time (s)", "Hold (s)", "Ease in", "Ease out", "Heading (°)", "Pan (°)", "Tilt (°)", "Roll (°)",
            "Focal length (mm)", "Focus (m)",
        ] {
            #expect(ShotsAccessibility.fieldExplanation(title)?.isEmpty == false, "\(title)")
        }
    }

    /// Raw values such as `closeUp`, `carMount` and `super35` must never be shown or spoken.
    @Test func cameraAndGaitChoicesHaveReadableUniqueNames() {
        func check(_ names: [String], raw: [String]) {
            #expect(Set(names).count == names.count)
            for (name, raw) in zip(names, raw) {
                #expect(!name.isEmpty)
                #expect(name.first?.isUppercase == true, "\(name)")
                #expect(!name.contains(where: { $0 == "_" }), "\(name)")
                if raw.contains(where: \.isUppercase) || raw.contains(where: \.isNumber) { #expect(name != raw) }
            }
        }
        check(Gait.allCases.map(\.displayName), raw: Gait.allCases.map(\.rawValue))
        check(Sensor.allCases.map(\.displayName), raw: Sensor.allCases.map(\.rawValue))
        check(Rig.allCases.map(\.displayName), raw: Rig.allCases.map(\.rawValue))
        check(Framing.Kind.allCases.map(\.displayName), raw: Framing.Kind.allCases.map(\.rawValue))
        #expect(Framing.Kind.allCases.allSatisfy { $0.explanation.hasSuffix(".") })
    }

    @Test func inspectMenuValueNamesWhatTheInspectorEdits() throws {
        let store = try ShotsStore(
            catalog: ContentCatalog.bundled(),
            document: ShotsSamples.twoPersonWalk(),
            saveURL: nil
        )
        let scene = try #require(store.currentScene)
        let shot = try #require(store.currentShot)
        let track = try #require(scene.blocking.first?.tracks.first)
        let entity = try #require(scene.entities.first { $0.id == track.entityID })
        let mark = try #require(track.marks.last)
        let cameraMark = try #require(shot.camera.marks.first)
        #expect(store.inspectedDescription == "Shot \(shot.name)")
        store.selection = .camera
        #expect(store.inspectedDescription == "Camera")
        store.selection = .entities([entity.id])
        #expect(store.inspectedDescription == entity.name)
        store.selection = .entities(scene.entities.prefix(3).map(\.id))
        #expect(store.inspectedDescription == "\(scene.entities[0].name) and 2 more")
        store.selection = .actorMark(entity.id, mark.id)
        #expect(store.inspectedDescription == ShotsAccessibility.markLabel(
            lane: entity.name, time: mark.time, gait: mark.gait
        ))
        #expect(!store.inspectedDescription.contains(mark.id))
        store.selection = .cameraMark(cameraMark.id)
        #expect(store.inspectedDescription == "Camera mark at 0.00 seconds")
    }

    @Test func exportProgressIsSpokenAsAPercentAndStepAndCanvasSizesAvoidDigitGrouping() {
        #expect(ShotsExportControls.progressValue(nil) == "Preparing")
        #expect(ShotsExportControls.progressValue(ExportProgress(step: "Drawing", fractionCompleted: 0.426))
            == "43 percent, Drawing")
        #expect(ShotsExportControls.progressValue(ExportProgress(step: "Done", fractionCompleted: 1.2))
            == "100 percent, Done")
        #expect(ShotsShotSettings.canvasName(ShotCanvas(width: 640, height: 1152)) == "640 × 1152")
        #expect(ShotsShotSettings.canvasName(ShotCanvas(width: 1152, height: 2048)) == "1152 × 2048")
    }
}
