import Foundation
import PrevisCore

/// Readable names and spoken text for Shots controls. Raw PrevisCore values are camel-case identifiers
/// (`closeUp`, `carMount`) and must never reach the screen or VoiceOver unchanged.
enum ShotsAccessibility {
    /// What the timeline does with the keyboard once it has focus (CONTRACTS section 7).
    static let timelineHint = "Left and Right arrows move the playhead one frame; hold Shift for one second. "
        + "Home and End jump to the start and end. Delete removes the selected mark. Space plays or pauses."

    /// VoiceOver label of a timeline mark pill: its lane (entity or camera), time and, for a person, gait.
    static func markLabel(lane: String, time: Double, gait: Gait?) -> String {
        let at = "mark at \(seconds(time))"
        guard let gait else { return "\(lane) \(at)" }
        return "\(lane), \(at), \(gait.displayName.lowercased())"
    }

    static func seconds(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
        return "\(text) \(value == 1 ? "second" : "seconds")"
    }

    /// Plain explanations of the mark and lens fields shared by the actor and camera mark inspectors.
    /// Ease semantics follow Blockout evaluate.ts: a leg uses `from.easeOut` and `to.easeIn`.
    static func fieldExplanation(_ title: String) -> String? {
        switch title {
        case "Time (s)": "When this mark is reached, in seconds from the start of the shot."
        case "Hold (s)": "How long to stay on this mark before moving on, in seconds."
        case "Ease in": "How gently movement slows on arriving at this mark: 0 is abrupt, 1 is gentle."
        case "Ease out": "How gently movement starts on leaving this mark: 0 is abrupt, 1 is gentle."
        case "Heading (°)": "Which way it faces, in degrees."
        case "Pan (°)": "Turn the camera left or right, in degrees."
        case "Tilt (°)": "Point the camera up or down, in degrees."
        case "Roll (°)": "Lean the picture's horizon, in degrees."
        case "Focal length (mm)": "Lens length: smaller numbers show more of the scene, larger numbers zoom in."
        case "Focus (m)": "Distance that is sharp, in metres. Nearer and farther things blur."
        default: nil
        }
    }

    /// A field title such as "X (m)" or "Pan (°)" read aloud as "X in metres" or "Pan in degrees".
    static func spokenTitle(_ title: String) -> String {
        let units = [
            "(m/s)": "in metres per second", "(mm)": "in millimetres", "(m)": "in metres",
            "(°)": "in degrees", "(s)": "in seconds",
        ]
        for (suffix, spoken) in units where title.hasSuffix(" " + suffix) {
            return String(title.dropLast(suffix.count + 1)) + " " + spoken
        }
        return title
    }
}

extension ShotsStore {
    /// What the inspector is showing, in words, for the Inspect menu's VoiceOver value.
    var inspectedDescription: String {
        guard let scene = currentScene, let shot = currentShot else { return "No shot" }
        func name(_ id: EntityID) -> String {
            scene.entities.first { $0.id == id }?.name ?? "Missing entity"
        }
        switch selection {
        case .none:
            return "Shot \(shot.name)"
        case .camera:
            return "Camera"
        case let .entities(ids):
            guard let first = ids.first else { return "Shot \(shot.name)" }
            return ids.count == 1 ? name(first) : "\(name(first)) and \(ids.count - 1) more"
        case let .actorMark(entityID, markID):
            let mark = scene.blocking.first { $0.id == shot.blockingTakeID }?
                .tracks.first { $0.entityID == entityID }?.marks.first { $0.id == markID }
            return ShotsAccessibility.markLabel(
                lane: name(entityID), time: mark?.time ?? 0, gait: mark?.gait ?? .walk
            )
        case let .cameraMark(markID):
            let time = shot.camera.marks.first { $0.id == markID }?.time ?? 0
            return ShotsAccessibility.markLabel(lane: "Camera", time: time, gait: nil)
        }
    }
}

extension Gait {
    var displayName: String {
        switch self {
        case .stand: "Stand"
        case .walk: "Walk"
        case .jog: "Jog"
        case .run: "Run"
        case .sit: "Sit"
        case .lie: "Lie down"
        case .crouch: "Crouch"
        case .gesture: "Gesture"
        case .fall: "Fall"
        }
    }
}

extension Sensor {
    var displayName: String {
        switch self {
        case .super16: "Super 16"
        case .super35: "Super 35"
        case .fullFrame: "Full frame"
        case .imax65: "IMAX 65"
        }
    }
}

extension Rig {
    var displayName: String {
        switch self {
        case .sticks: "Tripod"
        case .dolly: "Dolly"
        case .steadicam: "Steadicam"
        case .handheld: "Handheld"
        case .crane: "Crane"
        case .drone: "Drone"
        case .carMount: "Car mount"
        }
    }
}

extension Framing.Kind {
    var displayName: String {
        switch self {
        case .wide: "Wide"
        case .full: "Full body"
        case .medium: "Medium"
        case .closeUp: "Close-up"
        case .twoShot: "Two-shot"
        case .overShoulder: "Over shoulder"
        case .reverse: "Reverse"
        case .top: "Top down"
        case .low: "Low angle"
        case .dutch: "Dutch angle"
        }
    }

    /// Plain description of the camera mark each button adds at the playhead (PrevisCore `Framing.cameraMark`).
    var explanation: String {
        switch self {
        case .wide: "Show all of the first aim-lock subject with room around them."
        case .full: "Fit the first aim-lock subject from head to toe."
        case .medium: "Show the first aim-lock subject from about the waist up."
        case .closeUp: "Show the first aim-lock subject's head and shoulders."
        case .twoShot: "Fit every aim-lock subject across the frame."
        case .overShoulder: "Look past one subject's shoulder at the other. Needs two aim-lock subjects."
        case .reverse: "Move the camera to the opposite side of the subjects."
        case .top: "Look straight down from above."
        case .low: "Look up from knee height."
        case .dutch: "Tilt the horizon; press again to tilt the other way or level it."
        }
    }
}
