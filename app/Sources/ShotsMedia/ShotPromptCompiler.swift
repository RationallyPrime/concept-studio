import ConceptCore
import Foundation
import PrevisCore

/// How the camera moves over one leg, named as H3 prompts name moves.
public enum CameraMove: String, Codable, Sendable, CaseIterable {
    case push, pull, truckLeft, truckRight, orbitLeft, orbitRight, craneUp, craneDown
    case panLeft, panRight, tiltUp, tiltDown, zoomIn, zoomOut
    case `static`
}

public enum MoveSpeed: String, Codable, Sendable { case slow, medium, fast }

public enum MoveAmplitude: String, Codable, Sendable { case small, medium, large }

/// The facts a shot's H3 prompt is written from: only what the shot itself states.
public struct PromptFacts: Codable, Sendable, Equatable {
    public struct CameraLeg: Codable, Sendable, Equatable {
        public var fromFrame: Int
        public var toFrame: Int
        public var move: CameraMove
        public var speed: MoveSpeed
        public var amplitude: MoveAmplitude
        public var focalLength: [Double] // millimetres at the start and the end

        public init(
            fromFrame: Int,
            toFrame: Int,
            move: CameraMove,
            speed: MoveSpeed,
            amplitude: MoveAmplitude,
            focalLength: [Double]
        ) {
            self.fromFrame = fromFrame
            self.toFrame = toFrame
            self.move = move
            self.speed = speed
            self.amplitude = amplitude
            self.focalLength = focalLength
        }
    }

    public struct Subject: Codable, Sendable, Equatable {
        public var entityID: EntityID
        public var name: String
        public var noun: String
        public var appearance: String?
        public var marks: [Mark]

        public init(entityID: EntityID, name: String, noun: String, appearance: String? = nil, marks: [Mark] = []) {
            self.entityID = entityID
            self.name = name
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
    public var subjects: [Subject]
    public var props: [String]
    public var lighting: LightingPreset
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
        subjects: [Subject] = [],
        props: [String] = [],
        lighting: LightingPreset,
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

    public static func facts(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws -> PromptFacts {
        guard let shot = scene.shots.first(where: { $0.id == shotID }) else {
            throw ShotsMediaError("Scene \"\(scene.name)\" has no shot \(shotID).")
        }
        let take = scene.blocking.first { $0.id == shot.blockingTakeID }
        let marks = Dictionary(
            take?.tracks.map { ($0.entityID, $0.marks) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        var subjects: [PromptFacts.Subject] = [], props: [String] = []
        for entity in scene.entities {
            let asset = catalog.asset(entity.assetID)
            let noun = asset?.promptNoun ?? entity.name.lowercased()
            let entityMarks = marks[entity.id] ?? []
            guard asset.map({ $0.rig != .none }) ?? false || entity.label != nil || !entityMarks.isEmpty else {
                props.append(noun)
                continue
            }
            subjects.append(PromptFacts.Subject(
                entityID: entity.id,
                name: entity.name,
                noun: noun,
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
            cameraLegs: CameraLegs.classify(shot.camera.marks, frameCount: shot.frameCount),
            subjects: subjects,
            props: props,
            lighting: scene.lighting,
            setting: shot.notes.description,
            sound: shot.notes.sound,
            music: shot.notes.music
        )
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
        let run = try await stage.run(
            instructions: Skills.load(directory).instructions(),
            messages: [.user("Write the three sections for this shot. Its facts:\n\n" + factsJSON)],
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
                "description": .string("Music only the audience hears, or None."),
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

/// Camera legs classified from a shot's camera marks.
enum CameraLegs {
    private static let minimumTravel = 0.15 // metres
    private static let minimumTurn = 5.0 * .pi / 180
    private static let minimumZoom = log(1.1)

    static func classify(_ marks: [CameraMark], frameCount: Int) -> [PromptFacts.CameraLeg] {
        let marks = marks.sorted { $0.time < $1.time }
        let last = max(frameCount - 1, 0)
        func frame(_ time: Double) -> Int {
            min(FrameGrid.frame(atTime: time), last)
        }
        guard let first = marks.first else { return [] }
        var legs: [PromptFacts.CameraLeg] = []
        func hold(_ mark: CameraMark, from start: Int, to end: Int) {
            if end > start {
                legs.append(.init(
                    fromFrame: start, toFrame: end, move: .static, speed: .medium, amplitude: .medium,
                    focalLength: [mark.focalLength, mark.focalLength]
                ))
            }
        }
        hold(first, from: 0, to: frame(first.time))
        for (from, to) in zip(marks, marks.dropFirst()) {
            hold(from, from: frame(from.time), to: frame(from.time + from.hold))
            let start = frame(from.time + from.hold), end = frame(to.time)
            if end > start {
                legs.append(leg(from: from, to: to, frames: (start, end)))
            }
        }
        if let final = marks.last {
            hold(final, from: frame(final.time), to: last)
        }
        return legs
    }

    /// The dominant change between two marks, judged in the first mark's camera frame.
    private static func leg(from a: CameraMark, to b: CameraMark, frames: (Int, Int)) -> PromptFacts.CameraLeg {
        let seconds = Double(frames.1 - frames.0) / Double(FrameGrid.fps)
        let (dx, dy, dz) = (b.position.x - a.position.x, b.position.y - a.position.y, b.position.z - a.position.z)
        // Positive pan turns left and positive tilt looks up; the camera looks down its local −Z.
        let along = -dx * sin(a.pan) * cos(a.tilt) + dy * sin(a.tilt) - dz * cos(a.pan) * cos(a.tilt)
        let lateral = dx * cos(a.pan) - dz * sin(a.pan)
        let travel = (dx * dx + dy * dy + dz * dz).squareRoot()
        let pan = remainder(b.pan - a.pan, 2 * .pi), tilt = b.tilt - a.tilt
        let zoom = log(b.focalLength / a.focalLength), turn = max(abs(pan), abs(tilt))
        let move: CameraMove, speed: MoveSpeed, amplitude: MoveAmplitude
        if travel >= minimumTravel {
            if abs(dy) >= abs(along), abs(dy) >= abs(lateral) {
                move = dy > 0 ? .craneUp : .craneDown
            } else if abs(lateral) > abs(along) {
                // Turning against the sideways travel keeps the subject framed: that is an orbit.
                let orbits = abs(pan) >= minimumTurn && (lateral > 0) == (pan > 0)
                move = orbits ? (lateral > 0 ? .orbitRight : .orbitLeft) : (lateral > 0 ? .truckRight : .truckLeft)
            } else {
                move = along > 0 ? .push : .pull
            }
            (speed, amplitude) = (grade(travel / seconds, 0.4, 1.2), size(travel, 0.75, 3))
        } else if abs(zoom) >= minimumZoom {
            move = zoom > 0 ? .zoomIn : .zoomOut
            (speed, amplitude) = (grade(abs(zoom) / seconds, 0.15, 0.5), size(abs(zoom), log(1.3), log(2)))
        } else if turn >= minimumTurn {
            move = abs(pan) >= abs(tilt) ? (pan > 0 ? .panLeft : .panRight) : (tilt > 0 ? .tiltUp : .tiltDown)
            (speed, amplitude) = (grade(turn / seconds, 0.25, 0.8), size(turn, .pi / 12, .pi / 3))
        } else {
            (move, speed, amplitude) = (.static, .medium, .medium)
        }
        return .init(
            fromFrame: frames.0, toFrame: frames.1, move: move, speed: speed, amplitude: amplitude,
            focalLength: [a.focalLength, b.focalLength]
        )
    }

    private static func grade(_ rate: Double, _ slow: Double, _ fast: Double) -> MoveSpeed {
        rate < slow ? .slow : rate >= fast ? .fast : .medium
    }

    private static func size(_ amount: Double, _ small: Double, _ large: Double) -> MoveAmplitude {
        amount < small ? .small : amount >= large ? .large : .medium
    }
}

/// The offline template's prose.
enum PromptTemplate {
    static func description(_ facts: PromptFacts) -> String {
        var sentences = ["[Shot 1] The shot opens on the composition, subjects and places established by Picture 1."]
        if let setting = sentence(facts.setting) { sentences.append(setting) }
        for subject in facts.subjects {
            let who = "The \(bare(subject.noun))"
                + (subject.appearance.flatMap { sentence($0, ending: "") }.map { " (\($0))" } ?? "")
            sentences.append("\(who) \(actions(subject.marks)).")
        }
        if !facts.props.isEmpty {
            sentences.append("The scene also holds \(list(facts.props.map { article($0) })).")
        }
        sentences.append(camera(facts.cameraLegs))
        sentences.append("The shot ends settling into the poses, spacing and composition established by Picture 2.")
        return sentences.joined(separator: " ")
    }

    static func soundscape(_ facts: PromptFacts) -> String {
        if let sound = sentence(facts.sound) { return sound }
        let moving: Set<Gait> = [.walk, .jog, .run]
        let footsteps = facts.subjects.contains { $0.marks.contains { moving.contains($0.gait) } }
        return footsteps ? "Footsteps on the floor over quiet room tone." : "Quiet room tone."
    }

    static func music(_ facts: PromptFacts) -> String {
        sentence(facts.music) ?? "None."
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

    private static func camera(_ legs: [PromptFacts.CameraLeg]) -> String {
        guard let first = legs.first else { return "The camera holds a static shot." }
        let phrases = legs.map { leg -> String in
            var phrase = moves[leg.move] ?? "holds a static shot"
            guard leg.move != .static else { return phrase }
            if leg.amplitude != .medium { phrase += " with \(leg.amplitude.rawValue) amplitude" }
            if leg.speed != .medium { phrase += " at \(leg.speed.rawValue) speed" }
            if leg.move == .zoomIn || leg.move == .zoomOut, let end = leg.focalLength.last {
                phrase += " to a \(millimetres(end)) lens"
            }
            return phrase
        }
        let lens = first.focalLength.first.map { " on a \(millimetres($0)) lens" } ?? ""
        return "The camera " + phrases.joined(separator: ", then ") + lens + "."
    }

    private static let moves: [CameraMove: String] = [
        .push: "pushes in", .pull: "pulls out", .truckLeft: "trucks left", .truckRight: "trucks right",
        .orbitLeft: "arcs left around the subjects", .orbitRight: "arcs right around the subjects",
        .craneUp: "pedestals up", .craneDown: "pedestals down", .panLeft: "pans left", .panRight: "pans right",
        .tiltUp: "tilts up", .tiltDown: "tilts down", .zoomIn: "zooms in", .zoomOut: "zooms out",
        .static: "holds a static shot",
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
