import Foundation

/// Plain-language facts from the same evaluated frame used by composition and control exports.
public enum ShotStaging {
    public struct Subject: Sendable, Equatable {
        public var entityID: EntityID
        public var name: String
        public var horizontal: String
        public var depth: String
        public var visibleBody: String
        public var facing: String
        public var visibleFraction: Double
        public var headVisible: Bool
        public var feetVisible: Bool
        public var occluded: Bool
    }

    public static func subjects(in frame: SceneFrame) -> [Subject] {
        let actors = frame.entities.filter(\.isActor)
        let view = frame.camera.viewMatrix()
        let depths = actors.map { -view.transform($0.position).z }
        let nearest = depths.min() ?? 0
        let farthest = depths.max() ?? nearest
        return zip(actors, depths).map { actor, distance in
            let height = actor.bounds.max.y - actor.bounds.min.y
            let centre = Vec3(actor.position.x, actor.bounds.min.y, actor.position.z)
            let samples = (0 ... 20).map { index in
                Vec3(centre.x, centre.y + height * Double(index) / 20, centre.z)
            }
            let sampleVisibility = samples.map { visible($0, in: frame) }
            let indices = sampleVisibility.indices.filter { sampleVisibility[$0] }
            let low = Double(indices.first ?? 20) / 20
            let high = Double(indices.last ?? 0) / 20
            let midpoint = Vec3(centre.x, centre.y + height * 0.65, centre.z)
            let pixel = frame.project(midpoint)
            let content = frame.plate?.imageRect(in: frame.canvas.pixelSize)
            let normalizedX = ((pixel?.x ?? -1) - (content?.x ?? 0))
                / (content?.width ?? Double(frame.canvas.width))
            let horizontal = switch normalizedX {
            case ..<0: "off frame left"
            case ..<0.4: "left"
            case ...0.6: "centre"
            case ...1: "right"
            default: "off frame right"
            }
            let depth: String = if farthest - nearest < 1 {
                distance <= 6 ? "foreground" : "background"
            } else {
                distance < (nearest + farthest) / 2 ? "foreground" : "background"
            }
            return Subject(
                entityID: actor.id,
                name: actor.label?.text.isEmpty == false ? actor.label?.text ?? actor.name : actor.name,
                horizontal: horizontal,
                depth: depth,
                visibleBody: bodyDescription(low: low, high: high, visible: !indices.isEmpty),
                facing: facing(actor, camera: frame.camera),
                visibleFraction: Double(indices.count) / Double(samples.count),
                headVisible: sampleVisibility.last ?? false,
                feetVisible: sampleVisibility.first ?? false,
                occluded: samples.contains { frame.isOccluded($0) }
            )
        }
    }

    public static func description(frame: SceneFrame, shot: Shot) -> String {
        let plate: String
        if frame.usesProjectedLocation {
            let references = frame.referencePlates.isEmpty ? [frame.plate].compactMap(\.self) : frame.referencePlates
            plate = "Location view projected from \(references.map(\.name).joined(separator: ", "))."
        } else {
            plate = (frame.matchedReferencePlate ?? frame.plate).map { "Plate \($0.name)." } ?? "Grey stage."
        }
        let camera = frame.camera
        let degrees = camera.tilt * 180 / .pi
        let angle = abs(degrees) < 0.5 ? "level" : String(
            format: "tilted %.1f° %@", abs(degrees), degrees > 0 ? "up" : "down"
        )
        let framing = shot.requestedFraming.map { "Requested framing \(framingName($0)). " } ?? ""
        let height = String(format: "%.2f", camera.position.y)
        let lens = String(format: "%.0f", camera.focalLength)
        let roll = abs(camera.roll) < 0.001 ? "" : String(format: ", roll %.1f°", camera.roll * 180 / .pi)
        let cameraText = "\(framing)Camera \(height) m above the floor, \(angle)\(roll), \(lens) mm lens."
        let people = subjects(in: frame).map {
            "\($0.name) is \($0.horizontal) in the \($0.depth), \($0.visibleBody), \($0.facing)."
        }
        return ([plate, cameraText] + people).joined(separator: " ")
    }

    public static func framingName(_ kind: Framing.Kind) -> String {
        switch kind {
        case .wide: "wide"
        case .full: "head to boots"
        case .medium: "waist up"
        case .closeUp: "close-up"
        case .twoShot: "two-shot"
        case .overShoulder: "over the shoulder"
        case .reverse: "reverse"
        case .top: "overhead"
        case .low: "low angle"
        case .dutch: "Dutch angle"
        }
    }

    static func visible(_ point: Vec3, in frame: SceneFrame) -> Bool {
        guard let pixel = frame.project(point),
              pixel.x >= 0, pixel.x <= Double(frame.canvas.width),
              pixel.y >= 0, pixel.y <= Double(frame.canvas.height)
        else { return false }
        if let rect = frame.plate?.imageRect(in: frame.canvas.pixelSize),
           pixel.x < rect.x || pixel.x > rect.x + rect.width
           || pixel.y < rect.y || pixel.y > rect.y + rect.height {
            return false
        }
        return !frame.isOccluded(point)
    }

    private static func bodyDescription(low: Double, high: Double, visible: Bool) -> String {
        guard visible else { return "not visible" }
        if high < 0.9 { return "head cropped, body partly visible" }
        switch low {
        case ...0.05: return "visible head to boots"
        case ...0.3: return "visible from the knees up"
        case ...0.58: return "visible from the waist up"
        case ...0.8: return "head and shoulders visible"
        default: return "face partly visible"
        }
    }

    private static func facing(_ actor: EntityFrame, camera: CameraFrame) -> String {
        let forward = Vec3(-sin(actor.heading), 0, -cos(actor.heading))
        let towardCamera = Vec3(camera.position.x - actor.position.x, 0, camera.position.z - actor.position.z)
            .normalized
        let alignment = forward.dot(towardCamera)
        if alignment > 0.7 { return "facing the camera" }
        if alignment < -0.7 { return "facing away from the camera" }
        let right = camera.orientation.rotate(Vec3(1, 0, 0))
        return forward.dot(right) < 0 ? "facing frame left" : "facing frame right"
    }
}

/// Advisory checks for the calibrated still and the framing requested by the user.
public enum PlateDiagnostics {
    public static func problems(frame: SceneFrame, shot: Shot, sceneID: SceneID) -> [ShotsProblem] {
        guard let plate = frame.plate else { return [] }
        func warning(_ text: String, entity: EntityID? = nil) -> ShotsProblem {
            ShotsProblem(severity: .warning, message: text, sceneID: sceneID, shotID: shot.id, entityID: entity)
        }
        var result: [ShotsProblem] = []
        if !plate.calibration.confirmed {
            result.append(warning("\(plate.name)'s camera match is unconfirmed. Align the floor and horizon first."))
        }
        if frame.usesProjectedLocation {
            result.append(warning(
                "The shot camera extends beyond \(plate.name)'s photographed viewpoint. "
                    + "Check this view against the shared 3D set and other calibrated plates."
            ))
            result += reconstructionProblems(frame: frame, shot: shot, sceneID: sceneID)
        }
        let cameraInside = frame.setPieces.first { piece in
            let box = piece.bounds
            let point = frame.camera.position
            return point.x > box.min.x && point.x < box.max.x
                && point.y > box.min.y && point.y < box.max.y
                && point.z > box.min.z && point.z < box.max.z
        }
        if let cameraInside {
            result.append(warning("The camera is inside \(cameraInside.name). Move it outside that set piece."))
        }
        for subject in ShotStaging.subjects(in: frame) {
            if subject.visibleFraction == 0 {
                result.append(warning(
                    "\(subject.name) is outside the frame or fully hidden by the set. Adjust the staging.",
                    entity: subject.entityID
                ))
            } else if shot.requestedFraming == .wide || shot.requestedFraming == .full,
                      !subject.headVisible || !subject.feetVisible {
                result.append(warning(
                    "\(subject.name) cannot be seen head to boots here. "
                        + "The frame or a marked set piece hides part of the body.",
                    entity: subject.entityID
                ))
            } else if shot.requestedFraming == .closeUp, subject.visibleFraction > 0.55 {
                result.append(warning(
                    "\(subject.name) is framed wider than a close-up on this plate. "
                        + "Use a closer plate or revise the framing.",
                    entity: subject.entityID
                ))
            }
        }
        return result
    }

    static func reconstructionProblems(frame: SceneFrame, shot: Shot, sceneID: SceneID) -> [ShotsProblem] {
        let references = frame.referencePlates.isEmpty ? [frame.plate].compactMap(\.self) : frame.referencePlates
        var messages: [String] = []
        if !references.contains(where: \.calibration.confirmed) {
            messages.append("The reconstructed view has no confirmed reference camera. Confirm the plate matches.")
        }
        if frame.setPieces.isEmpty {
            messages.append(
                "Only the floor has a projection surface. Add shared solids for walls, tables and raised platforms."
            )
        }
        return messages.map {
            ShotsProblem(severity: .warning, message: $0, sceneID: sceneID, shotID: shot.id)
        }
    }
}
