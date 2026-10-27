import ConceptCore
import Foundation
import PrevisCore

/// The facts a shot's H3 prompt is written from: only what the shot itself states.
public struct PromptFacts: Codable, Sendable, Equatable {
    public struct CameraLeg: Codable, Sendable, Equatable {
        public var fromFrame: Int
        public var toFrame: Int
        public var move: CameraMove
        public var speed: MoveSpeed
        public var amplitude: MoveAmplitude
        public var also: [CameraMove] // a zoom or a roll that rides on the move
        public var focalLength: [Double] // millimetres at the start and the end

        public init(
            fromFrame: Int,
            toFrame: Int,
            move: CameraMove,
            speed: MoveSpeed,
            amplitude: MoveAmplitude,
            also: [CameraMove] = [],
            focalLength: [Double]
        ) {
            self.fromFrame = fromFrame
            self.toFrame = toFrame
            self.move = move
            self.speed = speed
            self.amplitude = amplitude
            self.also = also
            self.focalLength = focalLength
        }
    }

    /// Named by its catalog noun only: entity names and labels are editor text and stay out of prompts.
    public struct Subject: Codable, Sendable, Equatable {
        public var entityID: EntityID
        public var noun: String
        public var appearance: String?
        public var marks: [Mark]

        public init(entityID: EntityID, noun: String, appearance: String? = nil, marks: [Mark] = []) {
            self.entityID = entityID
            self.noun = noun
            self.appearance = appearance
            self.marks = marks
        }
    }

    /// From `frame` on, the subject moves in `gait`.
    public struct Mark: Codable, Sendable, Equatable {
        public var frame: Int
        public var gait: Gait

        public init(frame: Int, gait: Gait) {
            self.frame = frame
            self.gait = gait
        }
    }

    public var sceneRevision: Int
    public var frameCount: Int
    public var canvas: ShotCanvas
    public var duration: Double // seconds from the first frame to the last
    public var pictureTimes: [Double] // Picture 1 and Picture 2, in seconds
    public var middleGuides: [Int]
    public var sensor: Sensor
    public var cameraLegs: [CameraLeg]
    public var cameraSubjects: [EntityID] // what the camera aims at or rides with; empty for a free camera
    public var shake: CameraShake?
    public var subjects: [Subject]
    public var props: [String]
    public var lighting: String // Blockout's words for the scene's lighting preset
    public var setting: String
    public var sound: String
    public var music: String

    public init(
        sceneRevision: Int,
        frameCount: Int,
        canvas: ShotCanvas,
        duration: Double,
        pictureTimes: [Double],
        middleGuides: [Int] = [],
        sensor: Sensor,
        cameraLegs: [CameraLeg] = [],
        cameraSubjects: [EntityID] = [],
        shake: CameraShake? = nil,
        subjects: [Subject] = [],
        props: [String] = [],
        lighting: String,
        setting: String = "",
        sound: String = "",
        music: String = ""
    ) {
        self.sceneRevision = sceneRevision
        self.frameCount = frameCount
        self.canvas = canvas
        self.duration = duration
        self.pictureTimes = pictureTimes
        self.middleGuides = middleGuides
        self.sensor = sensor
        self.cameraLegs = cameraLegs
        self.cameraSubjects = cameraSubjects
        self.shake = shake
        self.subjects = subjects
        self.props = props
        self.lighting = lighting
        self.setting = setting
        self.sound = sound
        self.music = music
    }
}

/// Turns a shot into an H3 prompt in MiniMax's FL2VA structure (CONTRACTS section 8.3): a header that aligns
/// Picture 1 and Picture 2 with their exact times, then three sections. Code always writes the header.
public enum ShotPromptCompiler {
    static let sectionKeys = ["integrated_multimodal_description", "overall_soundscape", "non_diegetic_music"]

    /// About 512 Qwen3 text tokens of English at 3.5 characters a token, erring short. ai-toolkit trains H3 with
    /// captions capped at 512 text tokens; ComfyUI's H3 encoder sets no limit of its own.
    static let maximumCharacters = 1800

    /// Blockout's notable subjects (`src/engine/prompt.ts`): whatever moves or carries a label, and every person,
    /// vehicle and animal. One step past Blockout, whatever the camera aims at or rides with is a subject too, so the
    /// prompt can name it. Everything else is a prop.
    static let subjectCategories: Set = ["people", "vehicles", "animals"]

    public static func facts(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws -> PromptFacts {
        guard let shot = scene.shots.first(where: { $0.id == shotID }) else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has no shot \(shotID).")
        }
        let camera = try CameraLegs.read(scene: scene, shotID: shotID, catalog: catalog)
        let take = scene.blocking.first { $0.id == shot.blockingTakeID }
        let marks = Dictionary(
            take?.tracks.map { ($0.entityID, $0.marks) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        var subjects: [PromptFacts.Subject] = [], props: [String] = []
        // Reading the camera evaluated the scene, which refuses unknown assets, so every entity has one.
        for entity in scene.entities {
            guard let asset = catalog.asset(entity.assetID) else { continue }
            let entityMarks = marks[entity.id] ?? []
            guard !entityMarks.isEmpty || entity.label != nil || subjectCategories.contains(asset.category)
                || camera.subjects.contains(entity.id)
            else {
                // Blockout lists each noun once.
                if !props.contains(asset.promptNoun) { props.append(asset.promptNoun) }
                continue
            }
            subjects.append(PromptFacts.Subject(
                entityID: entity.id,
                noun: asset.promptNoun,
                appearance: shot.notes.characters.first { $0.entityID == entity.id }?.appearance,
                marks: entityMarks.filter { $0.time <= shot.duration }.map {
                    PromptFacts.Mark(frame: FrameGrid.frame(atTime: $0.time), gait: $0.gait)
                }
            ))
        }
        return PromptFacts(
            sceneRevision: scene.revision,
            frameCount: shot.frameCount,
            canvas: shot.canvas,
            duration: shot.duration,
            pictureTimes: [0, shot.duration],
            middleGuides: shot.guideFrames,
            sensor: shot.camera.sensor,
            cameraLegs: camera.legs,
            cameraSubjects: camera.subjects,
            shake: camera.shake,
            subjects: subjects,
            props: props,
            lighting: words(for: scene.lighting),
            setting: shot.notes.description,
            sound: shot.notes.sound,
            music: shot.notes.music
        )
    }

    /// Blockout's words for each lighting preset (`LIGHTING_WORDS` in `src/engine/prompt.ts`).
    static func words(for lighting: LightingPreset) -> String {
        switch lighting {
        case .day: "soft daylight"
        case .goldenHour: "warm golden-hour light"
        case .night: "night, cool moonlit ambience"
        case .interiorWarm: "warm interior lighting"
        case .interiorCool: "cool interior lighting"
        }
    }

    /// What stands between a stored prompt and a package, as sentences for the user: empty when the prompt was
    /// written from the scene as it now is and fits the length H3 adapters are trained on.
    static func problems(_ prompt: ShotPrompt, scene: PrevisScene) -> [String] {
        var problems: [String] = []
        if prompt.sceneRevision < scene.revision {
            problems.append(
                "The prompt was written from revision \(prompt.sceneRevision) of the scene, which is now at "
                    + "revision \(scene.revision), so it may not match the blocking; write it again."
            )
        }
        if prompt.text.count > maximumCharacters {
            problems.append(
                "The prompt is \(prompt.text.count) characters, over the \(maximumCharacters) that keep it within "
                    + "the 512 text tokens H3 adapters are trained on; shorten it."
            )
        }
        return problems
    }

    /// Deterministic and offline: every section is written from the facts, with a plain default when the shot
    /// has no notes for it.
    public static func template(_ facts: PromptFacts) -> ShotPrompt {
        assemble(facts, sections: [
            PromptTemplate.description(facts), PromptTemplate.soundscape(facts), PromptTemplate.music(facts),
        ], writtenBy: "template")
    }

    /// Asks the endpoint for the three sections under the bundled `h3-shot-prompt` skill.
    public static func write(_ facts: PromptFacts, endpoint: ResolvedEndpoint) async throws -> ShotPrompt {
        guard let directory = Bundle.module.url(
            forResource: "h3-shot-prompt", withExtension: nil, subdirectory: "Resources/Skills"
        ) else { throw ShotsMediaError("The bundled h3-shot-prompt skill is missing from this build.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let factsJSON = try String(bytes: encoder.encode(facts), encoding: .utf8) else {
            throw ShotsMediaError("The shot's prompt facts couldn't be written as JSON.")
        }
        let stage = StructuredStage<WrittenSections>(
            name: "shot prompt", endpoint: endpoint, schemaName: WrittenSections.schemaName,
            schema: WrittenSections.jsonSchema
        )
        // The header and the section keys share the budget with the sections.
        let budget = maximumCharacters - header(facts).count - sectionKeys.map { $0.count + 4 }.reduce(0, +)
        let run = try await stage.run(
            instructions: Skills.load(directory).instructions(),
            messages: [.user(
                "Write the three sections for this shot, under \(budget) characters together. Its facts:\n\n"
                    + factsJSON
            )],
            validate: { $0.problems }
        )
        return assemble(facts, sections: run.output.texts, writtenBy: endpoint.requested)
    }

    /// FL2VA's picture-alignment line, with Picture 2 at the last frame's time to two decimals.
    static func header(_ facts: PromptFacts) -> String {
        "How the reference pictures align with the target video — Picture 1 (from Shot 1) aligns with the "
            + "0.00-second mark of the target video; Picture 2 (from Shot 1) aligns with the "
            + "\(String(format: "%.2f", facts.duration))-second mark of the target video."
    }

    static func assemble(_ facts: PromptFacts, sections: [String], writtenBy: String) -> ShotPrompt {
        let keyed = zip(sectionKeys, sections).map { PromptSection(key: $0, text: $1) }
        let text = ([header(facts)] + keyed.map { "\($0.key): \($0.text)" }).joined(separator: "\n\n")
        return ShotPrompt(sections: keyed, text: text, sceneRevision: facts.sceneRevision, writtenBy: writtenBy)
    }
}

/// The model's reply: the three sections and nothing else.
struct WrittenSections: Decodable, Sendable {
    static let schemaName = "ShotPromptSections"
    static let jsonSchema: JSONValue = .object([
        "type": .string("object"),
        "title": .string(schemaName),
        "properties": .object([
            "integrated_multimodal_description": .object([
                "type": .string("string"),
                "description": .string(
                    "Begins with [Shot 1]: the path from Picture 1 to Picture 2, with the camera move."
                ),
            ]),
            "overall_soundscape": .object([
                "type": .string("string"),
                "description": .string("Ambient sound, action sounds and non-verbal human sounds across the clip."),
            ]),
            "non_diegetic_music": .object([
                "type": .string("string"),
                "description": .string("Music only the audience hears, or N/A."),
            ]),
        ]),
        "required": .array([
            .string("integrated_multimodal_description"), .string("overall_soundscape"), .string("non_diegetic_music"),
        ]),
        "additionalProperties": .bool(false),
    ])

    var integratedMultimodalDescription: String
    var overallSoundscape: String
    var nonDiegeticMusic: String

    private enum CodingKeys: String, CodingKey {
        case integratedMultimodalDescription = "integrated_multimodal_description"
        case overallSoundscape = "overall_soundscape"
        case nonDiegeticMusic = "non_diegetic_music"
    }

    var texts: [String] {
        [integratedMultimodalDescription, overallSoundscape, nonDiegeticMusic].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Empty sections, and sections that repeat their own key, go back to the model once.
    var problems: [String] {
        zip(ShotPromptCompiler.sectionKeys, texts).compactMap { key, text in
            if text.isEmpty { return "\(key) is empty." }
            return text.hasPrefix("\(key):") ? "Write \(key) without repeating its key." : nil
        }
    }
}

/// The offline template's prose.
enum PromptTemplate {
    static func description(_ facts: PromptFacts) -> String {
        var sentences = ["[Shot 1] The shot opens on the composition, subjects and places established by Picture 1."]
        if let light = sentence(facts.lighting) { sentences.append(light.prefix(1).uppercased() + light.dropFirst()) }
        if let setting = sentence(facts.setting) { sentences.append(setting) }
        for (subject, who) in zip(facts.subjects, references(facts.subjects)) {
            sentences.append("\(who) \(actions(subject.marks)).")
        }
        if !facts.props.isEmpty {
            sentences.append("The scene also holds \(list(facts.props.map { article($0) })).")
        }
        sentences.append(camera(facts.cameraLegs, around: target(facts)))
        if let shake = facts.shake {
            sentences.append("The camera shakes \(shake == .strong ? "strongly" : "slightly").")
        }
        sentences.append("The shot ends settling into the poses, spacing and composition established by Picture 2.")
        return sentences.joined(separator: " ")
    }

    static func soundscape(_ facts: PromptFacts) -> String {
        if let sound = sentence(facts.sound) { return sound }
        let moving: Set<Gait> = [.walk, .jog, .run]
        let footsteps = facts.subjects.contains { $0.marks.contains { moving.contains($0.gait) } }
        return footsteps ? "Footsteps on the floor over quiet room tone." : "Quiet room tone."
    }

    /// H3 writes `N/A` when there is no music only the audience hears.
    static func music(_ facts: PromptFacts) -> String {
        sentence(facts.music) ?? "N/A"
    }

    /// "The man (in a grey coat)" for each subject.
    private static func references(_ subjects: [PromptFacts.Subject]) -> [String] {
        zip(subjects, names(subjects)).map { subject, name in
            "The" + name.dropFirst(3)
                + (subject.appearance.flatMap { sentence($0, ending: "") }.map { " (\($0))" } ?? "")
        }
    }

    /// "the man" for each subject. Where Blockout lists each noun once, the template narrates every subject, so
    /// subjects that share both noun and appearance are told apart by order instead: "the first man".
    private static func names(_ subjects: [PromptFacts.Subject]) -> [String] {
        let keys = subjects.map { subject in
            "\(bare(subject.noun).lowercased())\u{0}\(subject.appearance.flatMap { sentence($0, ending: "") } ?? "")"
        }
        var seen: [String: Int] = [:]
        return zip(subjects, keys).map { subject, key in
            seen[key, default: 0] += 1
            let order = keys.filter { $0 == key }.count > 1 ? ordinal(seen[key, default: 1]) + " " : ""
            return "the \(order)\(bare(subject.noun))"
        }
    }

    /// Whom the camera's moves are about: the subjects it aims at or rides with, as the subject sentences name them,
    /// or else all of them.
    private static func target(_ facts: PromptFacts) -> (name: String, plural: Bool) {
        let named = zip(facts.subjects, references(facts.subjects).map { "the" + $0.dropFirst(3) })
        let aimed = facts.cameraSubjects.compactMap { id in named.first { $0.0.entityID == id }?.1 }
        if !aimed.isEmpty { return (list(aimed), aimed.count > 1) }
        let count = facts.subjects.count
        return (count == 0 ? "the scene" : count == 1 ? "the subject" : "the subjects", count > 1)
    }

    private static func ordinal(_ number: Int) -> String {
        let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        return number <= words.count ? words[number - 1] : "next"
    }

    private static func actions(_ marks: [PromptFacts.Mark]) -> String {
        let gaits = marks.sorted { $0.frame < $1.frame }.map(\.gait)
            .reduce(into: [Gait]()) { result, gait in if result.last != gait { result.append(gait) } }
        guard !gaits.isEmpty else { return "stays in place" }
        let verbs: [Gait: String] = [
            .stand: "stands", .walk: "walks", .jog: "jogs", .run: "runs", .sit: "sits", .lie: "lies down",
            .crouch: "crouches", .gesture: "gestures", .fall: "falls",
        ]
        return gaits.compactMap { verbs[$0] }.joined(separator: ", then ")
    }

    /// One sentence in H3's camera vocabulary: motion type, then amplitude and speed when they aren't medium.
    private static func camera(_ legs: [PromptFacts.CameraLeg], around target: (name: String, plural: Bool)) -> String {
        guard let first = legs.first else { return "The camera holds a static shot." }
        let phrases = legs.map { leg -> String in
            guard leg.move != .static else { return "holds a static shot" }
            var phrase = verb(leg.move, around: target.name)
            if leg.amplitude != .medium { phrase += " with \(leg.amplitude.rawValue) amplitude" }
            if leg.speed != .medium { phrase += " at \(leg.speed.rawValue) speed" }
            if [.zoomIn, .zoomOut].contains(leg.move), let end = leg.focalLength.last {
                phrase += " to a \(millimetres(end)) lens"
            }
            let riding = leg.also.map { Self.riding($0, on: leg, around: target) }
            return riding.isEmpty ? phrase : phrase + " while " + riding.joined(separator: " and ")
        }
        let opening = first.focalLength.first.map { "On a \(millimetres($0)) lens, the camera " } ?? "The camera "
        return opening + phrases.joined(separator: ", then ") + "."
    }

    /// What happens during a move: following a travelling subject, a zoom to the leg's end lens, or a roll.
    private static func riding(
        _ extra: CameraMove,
        on leg: PromptFacts.CameraLeg,
        around target: (name: String, plural: Bool)
    ) -> String {
        switch extra {
        // An orbit has already named whom it goes round.
        case .track where [.orbitLeft, .orbitRight].contains(leg.move):
            target.plural ? "following them" : "following it"
        case .track: "following \(target.name)"
        case .zoomIn, .zoomOut:
            "zooming \(extra == .zoomIn ? "in" : "out")"
                + (leg.focalLength.last.map { " to a \(millimetres($0)) lens" } ?? "")
        case .rollClockwise: "rolling clockwise"
        default: "rolling counter-clockwise"
        }
    }

    private static func verb(_ move: CameraMove, around target: String) -> String {
        switch move {
        // Blockout's own words for its orbits: "a quarter circle counter-clockwise around the subject".
        case .orbitLeft: "arcs counter-clockwise around \(target)"
        case .orbitRight: "arcs clockwise around \(target)"
        case .track: "follows \(target) in a tracking shot"
        default: verbs[move] ?? "holds a static shot"
        }
    }

    private static let verbs: [CameraMove: String] = [
        .push: "pushes in", .pull: "pulls out", .truckLeft: "trucks left", .truckRight: "trucks right",
        .craneUp: "pedestals up", .craneDown: "pedestals down", .panLeft: "pans left", .panRight: "pans right",
        .tiltUp: "tilts up", .tiltDown: "tilts down", .zoomIn: "zooms in", .zoomOut: "zooms out",
        .rollClockwise: "rolls clockwise", .rollCounterclockwise: "rolls counter-clockwise",
    ]

    private static func millimetres(_ value: Double) -> String {
        "\(Int(value.rounded())) mm"
    }

    /// The user's text as one sentence, or nil when it is blank.
    private static func sentence(_ text: String, ending: String = ".") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if ending.isEmpty { return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) }
        return [".", "!", "?"].contains(where: trimmed.hasSuffix) ? trimmed : trimmed + ending
    }

    /// Catalog nouns may already carry an article ("a man"); it is kept, never doubled.
    private static func article(_ noun: String) -> String {
        guard bare(noun) == noun, let first = noun.lowercased().first else { return noun }
        return ("aeiou".contains(first) ? "an " : "a ") + noun
    }

    private static func bare(_ noun: String) -> String {
        for article in ["a ", "an ", "the "] where noun.lowercased().hasPrefix(article) {
            return String(noun.dropFirst(article.count))
        }
        return noun
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
