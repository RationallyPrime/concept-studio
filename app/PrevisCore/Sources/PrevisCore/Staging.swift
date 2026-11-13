import Foundation

// Staging, CONTRACTS section 5.8: what a frame actually shows of each character. It answers three things from the
// evaluated frame alone, before any model runs: how much of each character is visible and what hides the rest,
// where they are in the frame and which way they face, and whether that is what the shot asks for.

/// How much of a character a shot is meant to show, counted from the head down.
public enum BodyExtent: String, Codable, Sendable, CaseIterable {
    case face, chestUp, waistUp, thighsUp, kneesUp, headToBoots

    /// As it reads after "shows <name> ".
    public var phrase: String {
        switch self {
        case .face: "in a close-up of the face"
        case .chestUp: "from the chest up"
        case .waistUp: "from the waist up"
        case .thighsUp: "from mid-thigh up"
        case .kneesUp: "from the knees up"
        case .headToBoots: "from head to boots"
        }
    }

    /// The lowest part of the body the shot must still show.
    var lowest: BodyLevel {
        switch self {
        case .face: .neck
        case .chestUp: .chest
        case .waistUp: .waist
        case .thighsUp: .midThigh
        case .kneesUp: .knees
        case .headToBoots: .feet
        }
    }
}

public struct FramingAsk: Codable, Sendable, Equatable {
    public var entityID: EntityID
    public var extent: BodyExtent

    public init(entityID: EntityID, extent: BodyExtent) {
        self.entityID = entityID
        self.extent = extent
    }
}

/// Heights on a person, from the top of the head down.
public enum BodyLevel: Int, Sendable, CaseIterable, Comparable {
    case crown, eyes, neck, chest, waist, hips, midThigh, knees, shins, feet

    public static func < (a: BodyLevel, b: BodyLevel) -> Bool {
        a.rawValue < b.rawValue
    }

    /// As it reads after "visible from head to ".
    var name: String {
        switch self {
        case .crown: "the top of the head"
        case .eyes: "the eyes"
        case .neck: "the neck"
        case .chest: "the chest"
        case .waist: "the waist"
        case .hips: "the hips"
        case .midThigh: "mid-thigh"
        case .knees: "the knees"
        case .shins: "mid-shin"
        case .feet: "boots"
        }
    }
}

public struct StagedCharacter: Sendable, Equatable {
    public enum Horizontal: String, Sendable { case left, centre, right }
    public enum Depth: String, Sendable { case foreground, midground, background }
    public enum Facing: String, Sendable {
        case camera, threeQuarterLeft, threeQuarterRight, profileLeft, profileRight, awayLeft, awayRight, away

        /// A full clause: which way the character faces, in frame terms.
        public var phrase: String {
            switch self {
            case .camera: "facing the camera"
            case .threeQuarterLeft: "turned three-quarters toward the camera, facing frame left"
            case .threeQuarterRight: "turned three-quarters toward the camera, facing frame right"
            case .profileLeft: "in profile, facing frame left"
            case .profileRight: "in profile, facing frame right"
            case .awayLeft: "turned three-quarters away from the camera, facing frame left"
            case .awayRight: "turned three-quarters away from the camera, facing frame right"
            case .away: "back to the camera"
            }
        }

        /// A short form for a table cell.
        public var short: String {
            switch self {
            case .camera: "to camera"
            case .threeQuarterLeft: "3/4 left"
            case .threeQuarterRight: "3/4 right"
            case .profileLeft: "profile left"
            case .profileRight: "profile right"
            case .awayLeft: "3/4 away, left"
            case .awayRight: "3/4 away, right"
            case .away: "back to camera"
            }
        }
    }

    /// What ends the visible part of a character.
    public enum Cut: Sendable, Equatable {
        case frame(String) // "bottom", "top", "left" or "right" edge of the frame
        case hidden(by: [String]) // names of the set pieces or props in front
    }

    /// A rectangle in fractions of the canvas, from the top left.
    public struct Box: Sendable, Equatable {
        public var x: Double, y: Double, width: Double, height: Double
    }

    public var entityID: EntityID
    public var name: String
    public var standIn: String // the colour name of this character's stand-in in the composition guide
    public var isPerson: Bool
    public var isVisible: Bool
    public var horizontal: Horizontal
    public var depth: Depth
    public var facing: Facing
    public var lowest: BodyLevel? // people: the lowest level visible in an unbroken run from the head
    public var crownVisible: Bool // people: false when the top of the head is cut
    public var cut: Cut? // what ends the visible part; nil when all of it shows
    public var visibleFraction: Double // 0...1 of the sample points
    public var headFraction: Double // the head's height as a fraction of the frame's; 0 for other things
    public var bodyFraction: Double // the standing height as a fraction of the frame's; can exceed 1
    public var distance: Double // metres from the camera along its view
    public var box: Box? // the visible part

    /// "from head to mid-thigh", "in full, from head to boots", or what a creature shows.
    public var extentPhrase: String {
        guard isVisible else { return "not visible" }
        guard isPerson, let lowest else {
            return visibleFraction > 0.95 ? "fully in frame" : "partly in frame"
        }
        let top = crownVisible ? "head" : "forehead"
        switch lowest {
        case .feet: return crownVisible ? "in full, from head to boots" : "from the forehead to boots"
        case .crown, .eyes: return "face only"
        case .neck: return "head only"
        default: return "from \(top) to \(lowest.name)"
        }
    }
}

public struct Staging: Sendable, Equatable {
    public var shotName: String
    public var plateName: String?
    public var canvas: ShotCanvas
    public var camera: CameraFrame
    public var sensor: Sensor
    public var framing: String // "medium two-shot"
    public var characters: [StagedCharacter]

    /// "1.52 m above the floor, tilted 7° down, 35 mm lens on Super 35, horizon level".
    public var cameraPhrase: String {
        let tilt = camera.tilt * 180 / .pi, roll = camera.roll * 180 / .pi
        let angle = abs(tilt) < 1.5 ? "level" : "tilted \(Int(abs(tilt).rounded()))° \(tilt < 0 ? "down" : "up")"
        let horizon = abs(roll) < 0.5 ? "horizon level" : "horizon rolled \(Int(abs(roll).rounded()))°"
        return String(format: "%.2f m above the floor, ", camera.position.y) + angle
            + ", \(Int(camera.focalLength.rounded())) mm lens on \(sensor.formatName), " + horizon
    }

    public var shapePhrase: String {
        let aspect = canvas.aspect
        if abs(aspect - 9.0 / 16) < 0.01 { return "vertical 9:16" }
        if abs(aspect - 16.0 / 9) < 0.02 { return "horizontal 16:9" }
        if abs(aspect - 1) < 0.01 { return "square" }
        return aspect < 1 ? "vertical" : "horizontal"
    }

    /// The staging in plain words, ready to paste into a prompt or a scene sheet: the plate, the framing, the
    /// camera, then one line per character.
    public func description() -> String {
        var lines: [String] = []
        if let plateName {
            lines.append("Set: the plate \"\(plateName)\", unchanged. Keep its camera angle, lens and furniture.")
        }
        lines.append("Framing: \(framing), \(shapePhrase).")
        lines.append("Camera: \(cameraPhrase).")
        for character in characters {
            lines.append(Self.line(for: character))
        }
        return lines.joined(separator: "\n")
    }

    /// Which stand-in is which character, for a caption under the composition guide.
    public func legend() -> String {
        let people = characters.filter(\.isVisible)
        guard !people.isEmpty else { return "No characters are in frame." }
        return people.map { "The \($0.standIn) stand-in is \($0.name)." }.joined(separator: " ")
            + " The stand-ins mark position, size and facing only; they are not the characters' look."
    }

    private static func line(for character: StagedCharacter) -> String {
        let who = "\(character.name) (\(character.standIn) stand-in)"
        guard character.isVisible else {
            switch character.cut {
            case let .hidden(names)?: return "\(who): hidden behind \(list(names))."
            case let .frame(edge)?: return "\(who): outside the frame, past its \(edge) edge."
            case nil: return "\(who): not in frame."
            }
        }
        var text = "\(who): frame \(character.horizontal.rawValue), \(character.depth.rawValue). "
            + "Visible \(character.extentPhrase)"
        switch character.cut {
        case let .hidden(names)?: text += "; \(list(names)) \(names.count == 1 ? "hides" : "hide") the rest"
        case let .frame(edge)?: text += "; the \(edge) of the frame cuts the rest"
        case nil: break
        }
        return text + ". " + character.facing.phrase.prefix(1).uppercased() + character.facing.phrase.dropFirst() + "."
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "the set"
        case 1: "the \(names[0])"
        default: names.dropLast().map { "the \($0)" }.joined(separator: ", ") + " and the \(names[names.count - 1])"
        }
    }
}

public extension Sensor {
    /// The film format's name as it reads in a sentence: "Super 35".
    var formatName: String {
        switch self {
        case .super16: "Super 16"
        case .super35: "Super 35"
        case .fullFrame: "full frame"
        case .imax65: "IMAX 65"
        }
    }
}

/// The colours of the stand-ins in a composition guide, in actor order. The guide and the staging description
/// both use them, so the words name the colour the picture shows.
public enum StandInPalette {
    public static let colors: [(name: String, color: RGB)] = [
        ("blue", RGB(hex: "#2f6fe0")), ("orange", RGB(hex: "#f08a24")), ("green", RGB(hex: "#35a853")),
        ("magenta", RGB(hex: "#d43f9c")), ("yellow", RGB(hex: "#e6c229")), ("cyan", RGB(hex: "#2bb5c9")),
        ("red", RGB(hex: "#d8402f")), ("purple", RGB(hex: "#7b52c7")),
    ]

    /// The stand-in of the actor at `index` among a frame's actors.
    public static func standIn(_ index: Int) -> (name: String, color: RGB) {
        colors[index % colors.count]
    }
}

public enum StagingAnalysis {
    /// What `frame` shows of each actor, in entity order.
    public static func characters(in frame: SceneFrame) -> [StagedCharacter] {
        let size = frame.canvas.pixelSize
        let occluders = frame.entities.filter { !$0.isActor }.flatMap(Occluder.all)
        let view = frame.camera.viewMatrix()
        let toCamera = frame.camera.orientation.conjugate
        return frame.entities.filter(\.isActor).enumerated().map { index, entity in
            Analyst(
                entity: entity, standIn: StandInPalette.standIn(index).name, camera: frame.camera, view: view,
                toCamera: toCamera, size: size, occluders: occluders
            ).character()
        }
    }

    /// The staging of `frame` for `shot`.
    public static func staging(shot: Shot, frame: SceneFrame) -> Staging {
        let characters = characters(in: frame)
        return Staging(
            shotName: shot.name,
            plateName: frame.plate?.name,
            canvas: frame.canvas,
            camera: frame.camera,
            sensor: shot.camera.sensor,
            framing: framing(of: characters),
            characters: characters
        )
    }

    /// The shot size in a director's words, from the character who is largest in frame.
    static func framing(of characters: [StagedCharacter]) -> String {
        let people = characters.filter { $0.isPerson && $0.isVisible }
        guard let lead = people.max(by: { $0.headFraction < $1.headFraction }), let lowest = lead.lowest else {
            return characters.contains(where: \.isVisible) ? "wide shot" : "empty frame"
        }
        let size = switch lowest {
        case .crown, .eyes, .neck: "extreme close-up"
        case .chest: lead.headFraction >= 0.22 ? "close-up" : "medium close-up"
        case .waist, .hips: "medium shot"
        case .midThigh, .knees: "medium-full shot"
        case .shins, .feet: lead.bodyFraction >= 0.6 ? "full shot" : "wide shot"
        }
        switch people.count {
        case 1: return size
        case 2: return size.replacingOccurrences(of: " shot", with: "") + " two-shot"
        default: return size.replacingOccurrences(of: " shot", with: "") + " group shot"
        }
    }

    /// Where the staging can't be what the shot asks for, or can't be at all, in plain sentences.
    static func problems(shot: Shot, staging: Staging, frame: SceneFrame, surfaces: SetSurfaces) -> [String] {
        var out: [String] = []
        let label = "Shot \"\(shot.name)\""
        for character in staging.characters where character.isPerson {
            guard let entity = frame.entities.first(where: { $0.id == character.entityID }) else { continue }
            if let blockerID = surfaces.blocker(x: entity.position.x, y: entity.position.y, z: entity.position.z),
               let blocker = frame.entities.first(where: { $0.id == blockerID }) {
                out.append(
                    "\(character.name) stands inside the \(blocker.name). Move \(character.name) in front of it, "
                        + "behind it or beside it."
                )
            }
            let ask = shot.asks.first { $0.entityID == character.entityID }
            guard character.isVisible else {
                // Someone the shot asks nothing of may well be out of frame.
                if ask != nil {
                    out.append("\(label) doesn't show \(character.name): \(Self.reason(character.cut)).")
                }
                continue
            }
            guard let ask, let lowest = character.lowest else { continue }
            out += Self.askProblems(
                ask,
                character: character,
                lowest: lowest,
                label: label,
                onPlate: frame.plate != nil
            )
        }
        return out
    }

    private static func askProblems(
        _ ask: FramingAsk, character: StagedCharacter, lowest: BodyLevel, label: String, onPlate: Bool
    ) -> [String] {
        let name = character.name, wanted = ask.extent
        let fixedCamera = onPlate ? " The camera can't move on a plate, so move \(name)" : " Move \(name) or the camera"
        if lowest < wanted.lowest {
            // Less shows than asked.
            switch character.cut {
            case let .hidden(names)?:
                return [
                    "\(label) asks for \(name) \(wanted.phrase), but \(Staging.list(names)) "
                        + "\(names.count == 1 ? "hides" : "hide") \(name) below \(lowest.name). Move \(name) clear of "
                        + "it, or ask for less of \(name).",
                ]
            case let .frame(edge)?:
                return [
                    "\(label) asks for \(name) \(wanted.phrase), but the \(edge) of the frame cuts \(name) at "
                        + "\(lowest.name).\(fixedCamera) further apart, or ask for less of \(name).",
                ]
            case nil:
                return []
            }
        }
        if wanted == .face || wanted == .chestUp, lowest > wanted.lowest {
            // More shows than asked: the character is too small in frame for a close shot.
            let needed = wanted == .face ? 0.3 : 0.2
            guard character.headFraction < needed * 0.8, character.headFraction > 0 else { return [] }
            let distance = character.distance * character.headFraction / needed
            return [
                "\(label) asks for \(name) \(wanted.phrase), but from here \(name) shows to \(lowest.name) and the "
                    + "head is \(Int((character.headFraction * 100).rounded()))% of the frame's height. "
                    + (onPlate
                        ? "This plate's camera reaches that only with \(name) about "
                        + String(format: "%.1f", distance) + " m away; otherwise the shot needs a closer plate."
                        : "Bring the camera to about " + String(format: "%.1f", distance) + " m from \(name)."),
            ]
        }
        return []
    }

    private static func reason(_ cut: StagedCharacter.Cut?) -> String {
        switch cut {
        case let .hidden(names)?: "\(Staging.list(names)) \(names.count == 1 ? "is" : "are") in front"
        case let .frame(edge)?: "the character is past the \(edge) edge of the frame"
        case nil: "the character is outside the frame"
        }
    }
}

// MARK: - The evaluator's view

public extension ShotEvaluator {
    /// What the frame at `index` shows of each actor: where they are, how much of them is visible, what hides the
    /// rest, and which way they face.
    func staging(atFrame index: Int = 0) -> Staging {
        StagingAnalysis.staging(shot: shot, frame: frame(index))
    }

    /// Where the first frame can't be what the shot asks for: a character hidden by the set, cut by the frame,
    /// too small for the close shot asked for, or standing inside furniture; and where a shot has left its plate.
    internal func stagingWarnings() -> [ShotsProblem] {
        let first = frame(0)
        var messages = StagingAnalysis.problems(
            shot: shot, staging: StagingAnalysis.staging(shot: shot, frame: first), frame: first, surfaces: surfaces
        )
        if let plate {
            let label = "Shot \"\(shot.name)\""
            if let match = plate.match {
                if !match.agrees(with: first.camera) || shot.camera.sensor != match.sensor {
                    messages.append(
                        "\(label) starts away from the camera of the plate \"\(plate.name)\", so its stand-ins "
                            + "won't sit on the plate's floor. Put the first camera mark back on the plate's camera."
                    )
                }
            } else {
                messages.append(
                    "The plate \"\(plate.name)\" has no camera match yet, so stand-ins over it have no true size "
                        + "or place. Match its camera first."
                )
            }
            let mismatch = PlateFit.widthMismatch(
                plate: plate.size,
                canvas: shot.canvas.pixelSize,
                sensor: shot.camera.sensor
            )
            if abs(mismatch) > 0.002 {
                let percent = String(format: "%.1f", abs(mismatch) * 100)
                messages.append(
                    "\(label) has a \(shot.canvas.width) × \(shot.canvas.height) canvas, which is \(percent)% "
                        + "\(mismatch > 0 ? "wider" : "narrower") than the plate \"\(plate.name)\". Control videos "
                        + "will not line up exactly with a key made at the plate's shape; use a canvas of the "
                        + "plate's shape, such as 576 × 1024 for a 9:16 plate."
                )
            }
        }
        return messages.map {
            ShotsProblem(severity: .warning, message: $0, sceneID: sceneID, shotID: shot.id)
        }
    }
}
