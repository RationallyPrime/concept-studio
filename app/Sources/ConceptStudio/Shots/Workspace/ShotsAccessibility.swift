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

    /// Plain explanations of the mark and lens fields, passed explicitly by each inspector.
    /// Ease semantics follow Blockout evaluate.ts: a leg uses `from.easeOut` and `to.easeIn`.
    enum FieldHelp {
        static let time = "When this mark is reached, in seconds from the start of the shot."
        static let hold = "How long to stay on this mark before moving on, in seconds."
        static let easeIn = "How gently movement slows on arriving at this mark: 0 is abrupt, 1 is gentle."
        static let easeOut = "How gently movement starts on leaving this mark: 0 is abrupt, 1 is gentle."
        static let arrivalHeading = "Which way the person faces on arriving at this mark, in degrees."
        static let pan = "Turn the camera left or right, in degrees. Aim lock overrides it."
        static let tilt = "Point the camera up or down, in degrees. Aim lock overrides it."
        static let roll = "Lean the picture's horizon, in degrees."
        static let focalLength = "Lens length: smaller numbers show more of the scene, larger numbers zoom in."
        static let focus = "Distance that is sharp, in metres. Nearer and farther things blur."
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
            // The entity the inspector edits: the first selected one in scene order, not click order.
            guard let first = scene.entities.first(where: { ids.contains($0.id) }) else { return "Shot \(shot.name)" }
            return ids.count == 1 ? first.name : "\(first.name) and \(ids.count - 1) more"
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

    /// Plain description of the camera pose each button sets at the playhead (PrevisCore `Framing.cameraMark`), for
    /// the subjects `ShotsFramingSubjects` picks from the selection as Blockout does. With aim lock off the camera
    /// view shows the framing as described; with it on, aim lock still chooses where the camera points.
    var explanation: String {
        switch self {
        case .wide: "Frame the selected person or prop whole, with room around them."
        case .full: "Frame the selected person or prop from head to toe."
        case .medium: "Frame the selected person from the waist up."
        case .closeUp: "Frame the selected person's face."
        case .twoShot: "Fit the selected people side by side, or every person when fewer than two are selected."
        case .overShoulder: "Look past the nearer person's shoulder at the other. Needs two people."
        case .reverse: "Swing the camera to the opposite side of the people."
        case .top: "Look straight down from above, fitting everyone in."
        case .low: "Look up from knee height at the first selected person, or at the scene's first person."
        case .dutch: "Tilt the horizon; press again to tilt the other way or level it."
        }
    }
}
