import Foundation
@testable import PrevisCore
import Testing

struct DecodingTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Every field set to something other than its default, so a misspelt key in a reader shows up as a diff.
    private func fullDocument() -> ShotsDocument {
        let mark = ActorMark(
            id: "m1", time: 1.5, hold: 0.5, easeIn: 0.1, easeOut: 0.2, position: Vec3(1, 2, 3), via: [Vec3(4, 5, 6)],
            gait: .run, arriveHeading: 0.7, joints: [.elbowL: 0.3, .headY: -0.2], boardID: "bus"
        )
        let camera = CameraMark(
            id: "c1", time: 2, hold: 0.25, easeIn: 0.3, easeOut: 0.4, position: Vec3(7, 8, 9), via: [Vec3(1, 1, 1)],
            pan: 0.1, tilt: 0.2, roll: 0.3, focalLength: 50, focusDistance: 4
        )
        let shot = Shot(
            id: "shot", name: "2B", frameCount: 39, canvas: ShotCanvas(width: 768, height: 768), blockingTakeID: "take",
            camera: ShotCamera(
                sensor: .imax65, rig: .handheld, rigIntensity: 0.5, seed: 5_000_000_000, mountID: "car",
                trackIDs: ["a", "b"], marks: [camera]
            ),
            guideFrames: [10, 20],
            notes: ShotNotes(
                description: "d", characters: [CharacterNote(entityID: "a", appearance: "tall")], sound: "s", music: "m"
            ),
            prompt: ShotPrompt(
                sections: [PromptSection(key: "k", text: "t")], text: "all", sceneRevision: 9, writtenBy: "template"
            ),
            results: [ShotResult(id: "r", kind: "video", path: "p", sceneRevision: 3)]
        )
        let entity = PrevisEntity(
            id: "a", assetID: "person.man", name: "Man", label: EntityLabel(text: "A", color: RGB(hex: "#e5484d")),
            placement: Placement(position: Vec3(1, 0, 2), heading: 1.2, scale: 1.1),
            attachment: EntityAttachment(parentID: "bus", offset: Vec3(0, 1, 0), rotation: .yaw(0.5))
        )
        let scene = PrevisScene(
            id: "scene", name: "S", revision: 4, lighting: .night, entities: [entity],
            blocking: [BlockingTake(id: "take", name: "Master", tracks: [Track(entityID: "a", marks: [mark])])],
            shots: [shot]
        )
        return ShotsDocument(version: 1, scenes: [scene])
    }

    @Test func everyFieldSurvivesAJSONRoundTrip() throws {
        let document = fullDocument()
        let data = try encoder.encode(document)
        #expect(try JSONDecoder().decode(ShotsDocument.self, from: data) == document)
        #expect(String(data: data, encoding: .utf8)?.contains("\"elbowL\"") == true)
    }

    @Test(arguments: [false, true])
    func theSamplesRoundTrip(small: Bool) throws {
        let document = ShotsSamples.twoPersonWalk(small: small)
        let data = try encoder.encode(document)
        #expect(try JSONDecoder().decode(ShotsDocument.self, from: data) == document)
    }

    @Test func absentFieldsTakeTheirDefaultsAndUnknownKeysAreIgnored() throws {
        let json = """
        {"future": [1, 2], "scenes": [{"id": "s", "colour": "teal",
          "entities": [{"id": "e", "assetID": "prim.cube", "extra": {"a": 1}}],
          "blocking": [{"id": "t", "tracks": [{"entityID": "e", "marks": [
            {"id": "m", "joints": {"elbowL": 0.5, "tentacleX": 9}}]}]}],
          "shots": [{"id": "h", "camera": {"marks": [{"id": "c"}]}}]}]}
        """
        let document = try JSONDecoder().decode(ShotsDocument.self, from: Data(json.utf8))
        #expect(document.version == ShotsDocument.currentVersion)
        let scene = try #require(document.scenes.first)
        #expect(scene.lighting == .day && scene.revision == 0 && scene.name.isEmpty)
        #expect(scene.entities.first?.placement == Placement(position: .zero, heading: 0, scale: 1))
        let mark = try #require(scene.blocking.first?.tracks.first?.marks.first)
        #expect(mark.joints == [.elbowL: 0.5])
        #expect(mark.gait == .stand && mark.via.isEmpty && mark.arriveHeading == nil)

        let shot = try #require(scene.shots.first)
        let made = Shot.make(id: "h", name: "", takeID: "", cameraMarkID: "c")
        #expect(shot.frameCount == made.frameCount && shot.canvas == made.canvas)
        #expect(shot.camera.sensor == made.camera.sensor && shot.camera.seed == made.camera.seed)
        #expect(shot.camera.marks == made.camera.marks)
    }

    @Test func aMissingIdentityIsAnErrorThatNamesIt() {
        let json = #"{"scenes": [{"id": "s", "entities": [{"id": "e"}]}]}"#
        #expect {
            try JSONDecoder().decode(ShotsDocument.self, from: Data(json.utf8))
        } throws: { error in
            "\(error)".contains("assetID")
        }
    }
}
