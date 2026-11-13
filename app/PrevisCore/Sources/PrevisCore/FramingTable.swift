import Foundation

// The framing table, CONTRACTS section 5.8: one row per shot of a scene, for the scene sheet. Every cell comes
// from the evaluated first frame, so the table says what the blocking shows, not what was intended.

public enum FramingTable {
    public struct Row: Sendable, Equatable {
        public var shotID: ShotID
        public var shot: String
        public var plate: String
        public var framing: String
        public var lens: String
        public var camera: String
        public var who: String
    }

    /// One row per shot, in scene order. A shot that can't be evaluated still gets a row, saying why.
    public static func rows(scene: PrevisScene, catalog: ContentCatalog) -> [Row] {
        scene.shots.map { shot in
            do {
                let staging = try ShotEvaluator(scene: scene, shotID: shot.id, catalog: catalog).staging()
                let camera = staging.camera
                let tilt = camera.tilt * 180 / .pi
                let angle = abs(tilt) < 1.5 ? "level" : "\(Int(abs(tilt).rounded()))° \(tilt < 0 ? "down" : "up")"
                return Row(
                    shotID: shot.id,
                    shot: shot.name,
                    plate: staging.plateName ?? "grey stage",
                    framing: staging.framing,
                    lens: "\(Int(camera.focalLength.rounded())) mm, \(staging.sensor.formatName)",
                    camera: String(
                        format: "%.2f m high, %@, at x %.1f z %.1f, pan %d°",
                        camera.position.y - staging.floorLevel, angle, camera.position.x, camera.position.z,
                        Int((camera.pan * 180 / .pi).rounded())
                    ),
                    who: staging.characters.map(cell).joined(separator: "; ")
                )
            } catch {
                return Row(
                    shotID: shot.id, shot: shot.name, plate: "", framing: "can't be evaluated", lens: "", camera: "",
                    who: error.localizedDescription
                )
            }
        }
    }

    /// The table as Markdown, ready to paste into a scene sheet.
    public static func markdown(scene: PrevisScene, catalog: ContentCatalog) -> String {
        var lines = [
            "| Shot | Plate | Framing | Lens | Camera | Who is where |",
            "|---|---|---|---|---|---|",
        ]
        for row in rows(scene: scene, catalog: catalog) {
            let cells = [row.shot, row.plate, row.framing, row.lens, row.camera, row.who]
            lines
                .append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "/") }
                    .joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ character: StagedCharacter) -> String {
        guard character.isVisible else { return "\(character.name): not in frame" }
        var text = "\(character.name): \(character.horizontal.rawValue), \(character.depth.rawValue), "
            + character.extentPhrase
        if case let .hidden(names)? = character.cut { text += " behind \(Staging.list(names))" }
        return text + ", \(character.facing.short)"
    }
}
