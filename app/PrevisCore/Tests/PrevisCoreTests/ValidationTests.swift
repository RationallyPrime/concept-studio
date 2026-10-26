import Foundation
@testable import PrevisCore
import Testing

struct ValidationTests {
    private let catalog: ContentCatalog
    private let document: ShotsDocument

    init() throws {
        catalog = try ContentCatalog.bundled()
        document = ShotsSamples.twoPersonWalk()
    }

    private func problems(_ edit: (inout PrevisScene) -> Void) -> [ShotsProblem] {
        var edited = document
        edit(&edited.scenes[0])
        return ShotsValidation.problems(in: edited, catalog: catalog)
    }

    private func errors(_ edit: (inout PrevisScene) -> Void) -> [ShotsProblem] {
        problems(edit).filter { $0.severity == .error }
    }

    @Test func theSamplesAndAnImportedProjectHaveNoProblems() throws {
        #expect(ShotsValidation.problems(in: document, catalog: catalog).isEmpty)
        #expect(ShotsValidation.problems(in: ShotsSamples.twoPersonWalk(small: true), catalog: catalog).isEmpty)
        let imported = try BlockoutImport.document(
            fromProjectJSON: ShotsSamples.blockoutProjectJSON(), catalog: catalog
        ).document
        #expect(ShotsValidation.problems(in: imported, catalog: catalog).isEmpty)
    }

    @Test func anUnknownAssetNamesTheAssetAndTheEntity() throws {
        let found = errors { $0.entities[0].assetID = "person.martian" }
        let message = try #require(found.first).message
        #expect(found.count == 1 && message.contains("person.martian") && message.contains("\"Man\""))
        #expect(found.first?.entityID == document.scenes[0].entities[0].id)
    }

    @Test func unresolvedReferencesAreErrorsThatNameThem() {
        let found = errors { scene in
            scene.entities[0].attachment = EntityAttachment(parentID: "ghost", offset: .zero, rotation: .identity)
            scene.blocking[0].tracks.append(Track(entityID: "phantom"))
            scene.blocking[0].tracks[0].marks[0].boardID = "bus-that-is-not-there"
            scene.shots[0].blockingTakeID = "no-take"
            scene.shots[0].camera.mountID = "no-mount"
            scene.shots[0].camera.trackIDs = ["no-target"]
            scene.shots[0].notes.characters = [CharacterNote(entityID: "nobody", appearance: "tall")]
        }
        let text = found.map(\.message).joined(separator: "\n")
        for name in ["ghost", "phantom", "bus-that-is-not-there", "no-take", "no-mount", "no-target", "nobody"] {
            #expect(text.contains(name), "no error names \(name)")
        }
    }

    @Test func anAttachmentCycleIsOneErrorNamingBothEntities() {
        let found = errors { scene in
            scene.entities[0].attachment = EntityAttachment(
                parentID: scene.entities[1].id,
                offset: .zero,
                rotation: .identity
            )
            scene.entities[1].attachment = EntityAttachment(
                parentID: scene.entities[0].id,
                offset: .zero,
                rotation: .identity
            )
        }
        #expect(found.count == 1)
        #expect(found.first?.message.contains("\"Man\"") == true && found.first?.message.contains("\"Woman\"") == true)
    }

    @Test func nonFiniteNumbersAreErrors() {
        let found = errors { scene in
            scene.entities[1].placement.position.x = .nan
            scene.blocking[0].tracks[0].marks[0].time = .infinity
            scene.shots[0].camera.marks[0].focalLength = .nan
        }
        #expect(found.count == 3, "\(found.map(\.message))")
    }

    @Test func anInvalidCanvasOrFrameCountIsAnError() {
        let found = errors { scene in
            scene.shots[0].canvas = ShotCanvas(width: 641, height: 1152)
            scene.shots[0].frameCount = 100
        }
        let text = found.map(\.message).joined(separator: "\n")
        #expect(
            found.count == 2 && text.contains("641 × 1152") && text.contains("100 frames") && text.contains("use 107"),
            "\(text)"
        )
    }

    @Test func guideFramesOutOfRangeAreErrorsAndDisorderIsAWarning() {
        let outOfRange = errors { $0.shots[0].guideFrames = [0, 61, 123, 500] }
        #expect(outOfRange.count == 3)
        let disorder = problems { $0.shots[0].guideFrames = [80, 61, 61] }
        #expect(disorder.filter { $0.severity == .error }.isEmpty && disorder.count == 1)
    }

    @Test func anUnknownGaitInAFileIsAnErrorThatNamesIt() throws {
        let mark = #"{"id": "m", "gait": "moonwalk"}"#
        #expect {
            try JSONDecoder().decode(ActorMark.self, from: Data(mark.utf8))
        } throws: { error in
            let text = "\(error)"
            return text.contains("\"moonwalk\" is not one of stand, walk")
        }
    }
}
