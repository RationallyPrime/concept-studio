import Foundation
import ImageIO
import PrevisCore

/// Copies original image bytes into the project so plate references survive moving the project.
enum ShotsPlateFile {
    static func importPlate(from source: URL, id: String, root: URL) throws -> LocationPlate {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ShotsPlateError("Choose a readable still image for the location plate.")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsAxes = (5 ... 8).contains(orientation)
        let dimensions = PixelSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
        let extensionName = source.pathExtension.isEmpty ? "image" : source.pathExtension.lowercased()
        let path = "plates/\(id).\(extensionName)"
        let destination = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return LocationPlate(
            id: id, name: source.deletingPathExtension().lastPathComponent,
            imagePath: path, pixelSize: dimensions
        )
    }
}

struct ShotsPlateError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

extension ShotsStore {
    var currentPlate: LocationPlate? {
        currentScene?.plates.first { $0.id == currentShot?.plateID }
    }

    func importPlate(from source: URL) throws {
        guard !isReadOnly else { throw ShotsEditingError.readOnly }
        guard let root = plateRootURL, let scene = currentScene, let shot = currentShot else {
            throw ShotsPlateError("Open a project and choose a shot before importing a location plate.")
        }
        let plate = try ShotsPlateFile.importPlate(from: source, id: newID("plate"), root: root)
        do {
            var commands: [ShotsCommand] = [.putPlate(scene.id, plate), .setPlate(shot.id, plate.id)]
            var canvas = shot.canvas
            if plate.pixelSize.width * 16 == plate.pixelSize.height * 9 {
                canvas = ShotCanvas(width: 576, height: 1024)
            } else if let matching = ShotCanvas.presets
                .first(where: { abs($0.aspect - plate.pixelSize.aspect) < 1e-9 }) {
                canvas = matching
            }
            commands.append(.setCanvas(shot.id, canvas))
            let keyCanvas = ShotCanvas(width: plate.pixelSize.width, height: plate.pixelSize.height)
            if keyCanvas.isValidKey, abs(keyCanvas.aspect - canvas.aspect) < 1e-9 {
                commands.append(.setKeyCanvas(shot.id, keyCanvas))
            }
            commands.append(.matchPlateCamera(shot.id))
            try perform(commands)
            showsPlateCalibration = true
        } catch {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(plate.imagePath))
            throw error
        }
    }

    func moveSelectedToPlatePoint(_ point: Vec3) {
        guard let scene = currentScene, let shot = currentShot, let frame,
              case let .entities(ids) = selection, let first = ids.first,
              let actor = frame.entities.first(where: { $0.id == first }) else { return }
        let delta = Vec3(point.x - actor.position.x, point.y - actor.position.y, point.z - actor.position.z)
        run(ViewportKeyboard.entityNudgeCommands(for: ids, by: delta, in: scene, currentShot: shot))
    }
}
