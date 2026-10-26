import ConceptCore
import Foundation
import PrevisCore
@testable import ShotsMedia
import Testing

@Suite("H3 prompts")
struct PromptTests {
    @Test func aModelWrittenPromptKeepsTheExactFormat() async throws {
        let facts = try sampleFacts(small: true)
        let reply = """
        {"integrated_multimodal_description": "[Shot 1] The man walks toward the woman.",
         "overall_soundscape": "Footsteps on a wooden floor.", "non_diegetic_music": "None."}
        """
        let prompt = try await ShotPromptCompiler.write(
            facts,
            endpoint: ResolvedEndpoint(client: FixedSections(reply: reply))
        )
        // 22 frames: Picture 2 is the last frame, 21/24 s in.
        #expect(prompt.text == """
        How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the 0.00-second \
        mark of the target video; Picture 2 (from Shot 1) aligns with the 0.88-second mark of the target video.

        integrated_multimodal_description: [Shot 1] The man walks toward the woman.

        overall_soundscape: Footsteps on a wooden floor.

        non_diegetic_music: None.
        """)
        #expect(prompt.writtenBy == "fake-model" && prompt.sceneRevision == facts.sceneRevision)
    }

    @Test func theSampleMovesAsAPushIn() throws {
        let full = try sampleFacts(small: false), small = try sampleFacts(small: true)
        #expect(full.cameraLegs.map(\.move) == [.push] && small.cameraLegs.map(\.move) == [.push])
        // The same 1.5 m push takes 5.1 s in the full sample and under a second in the small one.
        #expect(full.cameraLegs.first?.speed == .slow && small.cameraLegs.first?.speed == .fast)
    }

    @Test func aShotWithoutNotesStillHasAllThreeSections() throws {
        var scene = try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
        scene.shots[0].notes = ShotNotes(description: "", sound: "", music: "")
        let facts = try ShotPromptCompiler.facts(
            scene: scene,
            shotID: scene.shots[0].id,
            catalog: ContentCatalog.bundled()
        )
        let prompt = ShotPromptCompiler.template(facts)
        #expect(prompt.sections.map(\.key) == [
            "integrated_multimodal_description",
            "overall_soundscape",
            "non_diegetic_music",
        ])
        #expect(prompt.sections.allSatisfy { !$0.text.isEmpty }, "\(prompt.sections)")
        // H3 writes N/A when there is no music only the audience hears.
        #expect(prompt.sections.last?.text == "N/A")
        // Catalog nouns arrive with their article ("a man"), and the template names each subject once.
        #expect(prompt.sections[0].text.contains("The man walks, then stands."), "\(prompt.sections[0].text)")
        #expect(!prompt.text.contains("The a ") && !prompt.text.contains(" an a "))
        #expect(prompt.text.hasPrefix("How the reference pictures align with the target video — Picture 1"))
    }

    @Test func lightingIsDescribedInBlockoutsWords() throws {
        var scene = try sampleScene()
        scene.lighting = .night
        let facts = try facts(scene), words = ShotPromptCompiler.words(for: .night)
        #expect(facts.lighting == words)
        let sentence = words.prefix(1).uppercased() + words.dropFirst()
        #expect(PromptTemplate.description(facts).contains("Picture 1. \(sentence). "))
    }

    /// Blockout's notable subjects: whatever moves or carries a label, and every person, vehicle and animal.
    @Test func aParkedCarIsASubjectAndPropsAreListedOnce() throws {
        var scene = try sampleScene()
        let chair = try #require(scene.entities.first { $0.assetID == "furniture.chair" })
        scene.entities += [
            PrevisEntity(id: "ent_car", assetID: "vehicle.sedan", name: "Car", placement: chair.placement),
            PrevisEntity(id: "ent_chair2", assetID: "furniture.chair", name: "Chair 2", placement: chair.placement),
        ]
        let facts = try facts(scene)
        #expect(facts.subjects.map(\.noun).contains("a sedan car") && facts.props == ["a chair", "a wall"])
        #expect(PromptTemplate.description(facts).contains("The scene also holds a chair and a wall."))
    }

    @Test func subjectsThatShareANounAreToldApartByOrder() throws {
        var scene = try sampleScene()
        let index = try #require(scene.entities.firstIndex { $0.assetID == "person.woman" })
        scene.entities[index].assetID = "person.man"
        let prose = try PromptTemplate.description(facts(scene))
        #expect(prose.contains("The first man walks") && prose.contains("The second man walks"), "\(prose)")
    }

    /// Entity names and labels are editor text: neither reaches the prompt or the facts the model reads.
    @Test func namesAndLabelsStayOutOfThePrompt() throws {
        var scene = try sampleScene()
        scene.entities[0].name = "Ilvex"
        scene.entities[0].label = EntityLabel(text: "Hero", color: RGB(r: 1, g: 0, b: 0))
        let facts = try facts(scene)
        let json = try #require(try String(bytes: JSONEncoder().encode(facts), encoding: .utf8))
        let written = json + ShotPromptCompiler.template(facts).text
        #expect(!written.contains("Ilvex") && !written.contains("Hero"))
    }

    @Test func aStalePromptAndAnOverlongOneAreFlagged() throws {
        var scene = try sampleScene()
        let prompt = try ShotPromptCompiler.template(facts(scene))
        #expect(ShotPromptCompiler.problems(prompt, scene: scene) == [])
        scene.revision += 1
        #expect(ShotPromptCompiler.problems(prompt, scene: scene).map { $0.contains("revision 0") } == [true])
        var long = prompt
        long.text += String(repeating: "x", count: ShotPromptCompiler.maximumCharacters)
        long.sceneRevision = scene.revision
        #expect(ShotPromptCompiler.problems(long, scene: scene).map { $0.contains("characters") } == [true])
    }
}

extension PromptTests {
    /// Aimed at a park bench, which Blockout would list as a prop, the camera's move is about the bench by name.
    @Test func anAimedPropIsNamed() throws {
        var scene = try sampleScene()
        scene.entities.append(PrevisEntity(
            id: "ent_bench", assetID: "prop.bench", name: "Bench",
            placement: Placement(position: Vec3(0, 0, -1), heading: 0, scale: 1)
        ))
        scene.shots[0].camera.trackIDs = ["ent_bench"]
        var facts = try facts(scene)
        #expect(facts.subjects.map(\.entityID).contains("ent_bench") && !facts.props.contains("a park bench"))
        facts.cameraLegs = [PromptFacts.CameraLeg(
            fromFrame: 0, toFrame: 21, move: .orbitLeft, speed: .medium, amplitude: .medium, focalLength: [20, 20]
        )]
        let prose = PromptTemplate.description(facts)
        #expect(prose.contains("arcs counter-clockwise around the park bench"), "\(prose)")
    }

    /// The camera's moves are told about the subjects it aims at, by name, not about every subject in the scene.
    @Test func theCameraIsAboutTheSubjectItAimsAt() throws {
        var scene = try sampleScene()
        let man = scene.entities[0].id
        scene.shots[0].camera.trackIDs = [man]
        var facts = try facts(scene)
        #expect(facts.cameraSubjects == [man])
        facts.cameraLegs = [PromptFacts.CameraLeg(
            fromFrame: 0, toFrame: 21, move: .orbitLeft, speed: .medium, amplitude: .medium, also: [.track],
            focalLength: [20, 20]
        )]
        let prose = PromptTemplate.description(facts)
        #expect(prose.contains("arcs counter-clockwise around the man while following it"), "\(prose)")
        // Named as the subject sentences name him, appearance and all.
        facts.subjects[0].appearance = "in a grey coat"
        #expect(PromptTemplate.description(facts).contains("around the man (in a grey coat) while following it"))
    }
}

private func sampleScene() throws -> PrevisScene {
    try #require(ShotsSamples.twoPersonWalk(small: true).scenes.first)
}

private func facts(_ scene: PrevisScene) throws -> PromptFacts {
    try ShotPromptCompiler.facts(scene: scene, shotID: scene.shots[0].id, catalog: ContentCatalog.bundled())
}

/// A model that always answers with the same JSON.
private struct FixedSections: ModelClient {
    let requestedModel = "fake-model"
    let reply: String

    func request(
        instructions: String,
        messages: [ChatMessage],
        output: OutputRequest,
        settings: RequestSettings,
        onPartialText: (@Sendable (String) async -> Void)?
    ) async throws -> ModelReply {
        ModelReply(text: reply, servedModel: nil)
    }
}

private func sampleFacts(small: Bool) throws -> PromptFacts {
    let scene = try #require(ShotsSamples.twoPersonWalk(small: small).scenes.first)
    let shot = try #require(scene.shots.first)
    return try ShotPromptCompiler.facts(scene: scene, shotID: shot.id, catalog: ContentCatalog.bundled())
}
