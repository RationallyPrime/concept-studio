import Foundation
import PrevisCore

/// Plate edits share the same atomic validation, undo and save path as all blocking edits.
enum ShotsPlateEdits {
    static func apply(_ command: ShotsCommand, to document: inout ShotsDocument) throws -> Bool {
        switch command {
        case let .putSetPiece(sceneID, piece):
            guard let index = document.scenes.firstIndex(where: { $0.id == sceneID }) else {
                throw ShotsEditingError.missing("scene")
            }
            if let existing = document.scenes[index].setPieces.firstIndex(where: { $0.id == piece.id }) {
                document.scenes[index].setPieces[existing] = piece
            } else {
                document.scenes[index].setPieces.append(piece)
            }
        case let .removeSetPiece(sceneID, id):
            guard let index = document.scenes.firstIndex(where: { $0.id == sceneID }) else {
                throw ShotsEditingError.missing("scene")
            }
            document.scenes[index].setPieces.removeAll { $0.id == id }
        case let .putPlate(sceneID, plate):
            guard let index = document.scenes.firstIndex(where: { $0.id == sceneID }) else {
                throw ShotsEditingError.missing("scene")
            }
            if let existing = document.scenes[index].plates.firstIndex(where: { $0.id == plate.id }) {
                document.scenes[index].plates[existing] = plate
            } else {
                document.scenes[index].plates.append(plate)
            }
        case let .setPlate(shotID, plateID):
            try editShot(shotID, in: &document) { shot, scene in
                guard plateID == nil || scene.plates.contains(where: { $0.id == plateID }) else {
                    throw ShotsEditingError.missing("location plate")
                }
                shot.plateID = plateID
            }
        case let .matchPlateCamera(shotID):
            try editShot(shotID, in: &document) { shot, scene in
                guard let plate = scene.plates.first(where: { $0.id == shot.plateID }) else {
                    throw ShotsEditingError.missing("location plate")
                }
                let match = plate.calibration
                let markID = shot.camera.marks.first?.id ?? PrevisIDs.make("camera")
                shot.camera = ShotCamera(
                    sensor: match.sensor, rig: .sticks, rigIntensity: 0, seed: shot.camera.seed,
                    marks: [CameraMark(
                        id: markID, time: 0, hold: 0, easeIn: 0, easeOut: 0,
                        position: match.position, pan: match.pan, tilt: match.tilt,
                        roll: match.roll, focalLength: match.focalLength
                    )]
                )
            }
        case let .setKeyCanvas(shotID, canvas):
            try editShot(shotID, in: &document) { shot, _ in shot.keyCanvas = canvas }
        case let .setRequestedFraming(shotID, framing):
            try editShot(shotID, in: &document) { shot, _ in shot.requestedFraming = framing }
        default: return false
        }
        return true
    }

    private static func editShot(
        _ id: ShotID, in document: inout ShotsDocument,
        edit: (inout Shot, PrevisScene) throws -> Void
    ) throws {
        for sceneIndex in document.scenes.indices {
            if let shotIndex = document.scenes[sceneIndex].shots.firstIndex(where: { $0.id == id }) {
                let scene = document.scenes[sceneIndex]
                try edit(&document.scenes[sceneIndex].shots[shotIndex], scene)
                return
            }
        }
        throw ShotsEditingError.missing("shot")
    }
}
