import Foundation

// Blocking from a description, CONTRACTS section 5.9. A brief says, in frame terms, who is in a shot and where:
// "Ada frame left behind the long table, from mid-thigh up, facing right". The solver turns that into
// positions on the plate's floor through the plate's camera, so a scene's first pass of blocking can be prepared
// from the scene sheet and then corrected by hand.

public struct BlockingBrief: Codable, Sendable, Equatable {
    public enum Relation: String, Codable, Sendable { case on, behind, inFrontOf }
    public enum Facing: Codable, Sendable, Equatable {
        case camera, away, frameLeft, frameRight
        case toward(String) // another character of the brief, by name

        public init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            switch text {
            case "camera": self = .camera
            case "away": self = .away
            case "frameLeft": self = .frameLeft
            case "frameRight": self = .frameRight
            default:
                guard text.hasPrefix("toward:") else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "A facing is camera, away, frameLeft, frameRight or toward:<name>, "
                            + "not \"\(text)\"."
                    ))
                }
                self = .toward(String(text.dropFirst(7)))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .camera: try container.encode("camera")
            case .away: try container.encode("away")
            case .frameLeft: try container.encode("frameLeft")
            case .frameRight: try container.encode("frameRight")
            case let .toward(name): try container.encode("toward:" + name)
            }
        }
    }

    public struct Character: Codable, Sendable, Equatable {
        public var name: String // an entity of the scene by name, or a new one
        public var asset: String? // for a new entity; nil = person.man
        public var frameX: Double? // across the frame, 0 at its left edge to 1 at its right; nil = spread evenly
        public var show: BodyExtent? // how much of them the shot shows; on open floor it sets how near they stand
        public var relation: Relation? // where they stand relative to `piece`
        public var piece: String? // a set piece of the scene, by name
        public var facing: Facing? // nil = the camera

        public init(
            name: String,
            asset: String? = nil,
            frameX: Double? = nil,
            show: BodyExtent? = nil,
            relation: Relation? = nil,
            piece: String? = nil,
            facing: Facing? = nil
        ) {
            self.name = name
            self.asset = asset
            self.frameX = frameX
            self.show = show
            self.relation = relation
            self.piece = piece
            self.facing = facing
        }
    }

    public var shot: String // the shot's name; an existing shot of that name is blocked again
    public var plate: String? // a plate of the scene by name or id; nil = its first plate
    public var characters: [Character]

    public init(shot: String, plate: String? = nil, characters: [Character] = []) {
        self.shot = shot
        self.plate = plate
        self.characters = characters
    }
}

public extension Shot {
    /// Puts the shot on a plate's camera: the plate's film format, and the first camera mark at the plate's
    /// position, angles and lens. A canvas of another shape than a 9:16 plate becomes 576 × 1024. A plate without
    /// a match changes only the canvas; the camera follows when the match is made.
    mutating func block(over plate: LocationPlate) {
        plateID = plate.id
        let mismatch = PlateFit.widthMismatch(plate: plate.size, canvas: canvas.pixelSize, sensor: camera.sensor)
        if abs(mismatch) > 0.002, abs(plate.aspect - 9.0 / 16) < 0.002 {
            canvas = .portrait9x16
        }
        guard let match = plate.match else { return }
        camera.sensor = match.sensor
        if camera.marks.isEmpty {
            camera.marks = [match.cameraMark(id: "\(id)_plate_camera")]
            return
        }
        camera.marks.sort { $0.time < $1.time }
        camera.marks[0].position = match.position
        camera.marks[0].pan = match.pan
        camera.marks[0].tilt = match.tilt
        camera.marks[0].roll = match.roll
        camera.marks[0].focalLength = match.focalLength
    }
}

public enum BlockingSolver {
    /// Blocks `brief` in `scene`: makes or reuses its shot on the plate, makes or moves each character, and records
    /// what the shot asks to show. Returns the shot and, in plain sentences, whatever the plate could not give.
    /// The scene is unchanged when this throws.
    public static func apply(
        _ brief: BlockingBrief,
        to scene: inout PrevisScene,
        catalog: ContentCatalog
    ) throws -> (shotID: ShotID, notes: [String]) {
        var working = scene
        guard let plate = plate(named: brief.plate, in: working) else {
            throw problem(
                brief.plate.map { "The scene has no plate named \"\($0)\". Add the plate, or name one it has." }
                    ?? "The scene has no plate. Add the location's plate first."
            )
        }
        guard let match = plate.match else {
            throw problem("The plate \"\(plate.name)\" has no camera match yet. Match its camera, then block again.")
        }
        guard let take = working.blocking.first else { throw problem("The scene has no take to block in.") }
        guard !brief.characters.isEmpty else { throw problem("The description names nobody to place.") }

        let shotIndex: Int
        if let existing = working.shots
            .firstIndex(where: { $0.name.caseInsensitiveCompare(brief.shot) == .orderedSame }) {
            shotIndex = existing
        } else {
            working.shots.append(.make(
                id: PrevisIDs.make("shot"), name: brief.shot, takeID: take.id, cameraMarkID: PrevisIDs.make("camera")
            ))
            shotIndex = working.shots.count - 1
        }
        working.shots[shotIndex].block(over: plate)
        let shotID = working.shots[shotIndex].id
        // A brief stages people for this shot alone, so the shot gets its own blocking when it shares one.
        let takeID = working.giveOwnBlocking(to: shotID, takeID: PrevisIDs.make("take")) ?? take.id
        let canvas = working.shots[shotIndex].canvas.pixelSize
        let camera = match.camera(aspect: canvas.aspect)

        let ids = try characters(of: brief, in: &working, near: match, catalog: catalog)

        let count = Double(brief.characters.count)
        for (index, character) in brief.characters.enumerated() {
            let target = min(max(character.frameX ?? (Double(index) + 1) / (count + 1), 0.04), 0.96)
            let pixel = target * Double(canvas.width)
            let position: Vec3
            if let relation = character.relation, let pieceName = character.piece {
                guard let piece = setPiece(named: pieceName, in: working) else {
                    throw problem(
                        "\"\(character.name)\" is placed by the \"\(pieceName)\", but the scene has no set piece of "
                            + "that name. Add it and fit it to the plate first."
                    )
                }
                position = beside(piece, relation, column: pixel, camera: camera, size: canvas)
            } else {
                position = try onFloor(
                    ids[index], show: character.show, column: pixel, scene: working,
                    shot: Setting(shotID: shotID, take: takeID, camera: camera, size: canvas), catalog: catalog
                )
            }
            move(ids[index], to: position, in: &working, take: takeID)
        }
        for (index, character) in brief.characters.enumerated() {
            let heading = heading(
                for: character.facing ?? .camera, of: ids[index], brief: brief, ids: ids, scene: working,
                take: takeID, camera: camera
            )
            turn(ids[index], to: heading, in: &working, take: takeID)
        }
        working.shots[shotIndex].asks = working.shots[shotIndex].asks.filter { !ids.contains($0.entityID) }
            + zip(ids, brief.characters).compactMap { id, character in
                character.show.map { FramingAsk(entityID: id, extent: $0) }
            }

        let evaluator = try ShotEvaluator(scene: working, shotID: shotID, catalog: catalog)
        let notes = evaluator.stagingWarnings().map(\.message)
        scene = working
        return (shotID, notes)
    }

    /// The entity of each character of the brief, in order: the scene's own by name, or a new one standing in
    /// front of the plate's camera. Everyone exists before anyone is placed, so "facing Ben" can find Ben.
    private static func characters(
        of brief: BlockingBrief, in scene: inout PrevisScene, near match: PlateMatch, catalog: ContentCatalog
    ) throws -> [EntityID] {
        try brief.characters.enumerated().map { index, character in
            if let existing = scene.entities.first(where: {
                $0.setPiece == nil && $0.name.caseInsensitiveCompare(character.name) == .orderedSame
            }) {
                return existing.id
            }
            let assetID = character.asset ?? "person.man"
            guard catalog.asset(assetID) != nil else {
                throw problem("\"\(character.name)\" asks for the asset \(assetID), which the catalog doesn't have.")
            }
            let id = PrevisIDs.make("entity")
            let start = Vec3(
                match.position.x - 4 * sin(match.pan) + Double(index), 0, match.position.z - 4 * cos(match.pan)
            )
            scene.entities.append(PrevisEntity(
                id: id, assetID: assetID, name: character.name,
                placement: Placement(position: start, heading: 0, scale: 1)
            ))
            return id
        }
    }

    // MARK: Finding things by name

    private static func plate(named name: String?, in scene: PrevisScene) -> LocationPlate? {
        guard let name, !name.isEmpty else { return scene.plates.first }
        let wanted = name.lowercased()
        return scene.plates.first { $0.id == name || $0.name.lowercased() == wanted }
            ?? scene.plates.first { $0.name.lowercased().hasSuffix(" " + wanted) }
            ?? scene.plates.first { $0.name.lowercased().contains(wanted) }
    }

    private static func setPiece(named name: String, in scene: PrevisScene) -> PrevisEntity? {
        let wanted = name.lowercased()
        let pieces = scene.entities.filter { $0.setPiece != nil }
        return pieces.first { $0.name.lowercased() == wanted } ?? pieces.first { $0.name.lowercased().contains(wanted) }
            ?? pieces.first { wanted.contains($0.name.lowercased()) }
    }

    // MARK: Placing

    /// One side of a set piece: which way it faces, how far it is from the centre, and the edge along it.
    private struct Side {
        var normal: Vec3, reach: Double, along: Vec3, span: Double
    }

    /// A place on, behind or in front of a set piece whose column in the frame is `column`. "Behind" is the
    /// side away from the camera and "in front" the side toward it, whichever way the piece is turned.
    private static func beside(
        _ entity: PrevisEntity, _ relation: BlockingBrief.Relation, column: Double, camera: CameraFrame,
        size: PixelSize
    ) -> Vec3 {
        guard let piece = entity.setPiece else { return entity.placement.position }
        let placement = entity.placement
        let scale = placement.scale
        let half = Vec3(piece.size.x * scale / 2, piece.size.y * scale, piece.size.z * scale / 2)
        // The piece's own X and Z axes in the world.
        let axisX = Vec3(cos(placement.heading), 0, -sin(placement.heading))
        let axisZ = Vec3(sin(placement.heading), 0, cos(placement.heading))
        let centre = placement.position
        let chest = 1.2
        func miss(_ point: Vec3) -> Double {
            guard let pixel = camera.project(Vec3(point.x, point.y + chest, point.z), size: size) else {
                return .infinity
            }
            return abs(pixel.x - column)
        }
        var candidates: [Vec3] = []
        switch relation {
        case .on:
            let top = centre.y + half.y
            for u in stride(from: -1.0, through: 1.0, by: 0.05) {
                for v in stride(from: -0.8, through: 0.8, by: 0.2) {
                    let inset = Vec3(max(half.x - 0.3, 0) * u, 0, max(half.z - 0.3, 0) * v)
                    candidates.append(Vec3(
                        centre.x + axisX.x * inset.x + axisZ.x * inset.z, top,
                        centre.z + axisX.z * inset.x + axisZ.z * inset.z
                    ))
                }
            }
        case .behind, .inFrontOf:
            let away = Vec3(centre.x - camera.position.x, 0, centre.z - camera.position.z).normalized
            let sign = relation == .behind ? 1.0 : -1.0
            // The side whose outward direction points most away from the camera, or most toward it.
            let sides = [
                Side(normal: axisX, reach: half.x, along: axisZ, span: half.z),
                Side(normal: axisX * -1, reach: half.x, along: axisZ, span: half.z),
                Side(normal: axisZ, reach: half.z, along: axisX, span: half.x),
                Side(normal: axisZ * -1, reach: half.z, along: axisX, span: half.x),
            ]
            let side = sides.max { $0.normal.dot(away) * sign < $1.normal.dot(away) * sign } ?? sides[0]
            let gap = relation == .behind ? 0.45 : 0.6
            for u in stride(from: -1.0, through: 1.0, by: 0.004) {
                let base = centre + side.normal * (side.reach + gap) + side.along * (side.span * u)
                candidates.append(Vec3(base.x, 0, base.z))
            }
        }
        return candidates.min { miss($0) < miss($1) } ?? centre
    }

    /// The shot a character is being placed in: its take, and the plate's camera on its canvas.
    private struct Setting {
        var shotID: ShotID, take: TakeID, camera: CameraFrame, size: PixelSize
    }

    /// A place on the open floor in the frame's `column`, as near the camera as shows what `show` asks for.
    /// Each candidate distance is judged by the staging analysis itself, so the solver and the warnings agree.
    private static func onFloor(
        _ id: EntityID, show: BodyExtent?, column: Double, scene: PrevisScene, shot: Setting,
        catalog: ContentCatalog
    ) throws -> Vec3 {
        let (shotID, take, camera, size) = (shot.shotID, shot.take, shot.camera, shot.size)
        let forward = Vec3(-sin(camera.pan), 0, -cos(camera.pan)), right = Vec3(cos(camera.pan), 0, -sin(camera.pan))
        let wanted = show ?? .headToBoots
        // The part of the body that should sit in the column: the head for a close shot, the middle otherwise.
        let entity = scene.entities.first { $0.id == id }
        let stature = (entity.flatMap { catalog.asset($0.assetID) }?.height ?? 1.75) * (entity?.placement.scale ?? 1)
        let aim = stature * (wanted == .face || wanted == .chestUp ? 0.92 : 0.62)
        func point(at distance: Double) -> Vec3 {
            // Slide sideways until that part sits in the column.
            var low = -distance * 3, high = distance * 3
            let base = Vec3(camera.position.x, 0, camera.position.z) + forward * distance
            for _ in 0 ..< 40 {
                let middle = (low + high) / 2
                let candidate = base + right * middle
                let pixel = camera.project(Vec3(candidate.x, aim, candidate.z), size: size)?.x ?? column
                if pixel < column { low = middle } else { high = middle }
            }
            return base + right * ((low + high) / 2)
        }
        var best: (score: Double, position: Vec3)?
        var distance = 0.5
        while distance < 60 {
            let candidate = point(at: distance)
            var trial = scene
            move(id, to: candidate, in: &trial, take: take)
            let staged = try ShotEvaluator(scene: trial, shotID: shotID, catalog: catalog).staging()
            if let character = staged.characters.first(where: { $0.entityID == id }), character.isVisible,
               let lowest = character.lowest, character.crownVisible || wanted == .face {
                // (A close-up may cut the top of the head; nothing wider may.)
                // Showing less than asked is worse than showing more. Among distances that show exactly what
                // is asked, the furthest wins: the widest framing that is still that shot size. A full figure
                // instead keeps some floor under its boots.
                var score = Double(abs(lowest.rawValue - wanted.lowest.rawValue)) * (lowest < wanted.lowest ? 3 : 1)
                score += wanted == .headToBoots ? abs(character.bodyFraction - 0.8) : character.bodyFraction * 0.01
                if best == nil || score < (best?.score ?? .infinity) { best = (score, candidate) }
            }
            distance *= 1.08
        }
        return best?.position ?? point(at: 4)
    }

    private static func heading(
        for facing: BlockingBrief.Facing, of id: EntityID, brief: BlockingBrief, ids: [EntityID],
        scene: PrevisScene, take: TakeID, camera: CameraFrame
    ) -> Double {
        let position = Self.position(of: id, in: scene, take: take)
        func toward(_ target: Vec3) -> Double {
            headingOf(dx: target.x - position.x, dz: target.z - position.z)
        }
        let right = camera.orientation.rotate(Vec3(1, 0, 0))
        switch facing {
        case .camera: return toward(camera.position)
        case .away: return toward(camera.position) + .pi
        case .frameRight: return headingOf(dx: right.x, dz: right.z)
        case .frameLeft: return headingOf(dx: -right.x, dz: -right.z)
        case let .toward(name):
            guard let index = brief.characters
                .firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                let other = scene.entities.first(where: { $0.id == ids[index] }), other.id != id
            else { return toward(camera.position) }
            return toward(Self.position(of: other.id, in: scene, take: take))
        }
    }

    /// Where an entity stands at the first frame of a take: its first mark there, or its placement.
    private static func position(of id: EntityID, in scene: PrevisScene, take: TakeID) -> Vec3 {
        let marks = scene.blocking.first { $0.id == take }?.tracks.first { $0.entityID == id }?.marks ?? []
        return marks.min { $0.time < $1.time }?.position
            ?? scene.entities.first { $0.id == id }?.placement.position ?? .zero
    }

    /// Stands an entity at `position` in a take. Its marks there all move with it, so a character that already
    /// has moves keeps them. Without marks in the take, its placement moves.
    private static func move(_ id: EntityID, to position: Vec3, in scene: inout PrevisScene, take: TakeID) {
        guard let index = scene.entities.firstIndex(where: { $0.id == id }) else { return }
        let delta = position - Self.position(of: id, in: scene, take: take)
        guard let takeIndex = scene.blocking.firstIndex(where: { $0.id == take }),
              let track = scene.blocking[takeIndex].tracks.firstIndex(where: { $0.entityID == id }),
              !scene.blocking[takeIndex].tracks[track].marks.isEmpty
        else {
            scene.entities[index].placement.position = position
            return
        }
        for mark in scene.blocking[takeIndex].tracks[track].marks.indices {
            scene.blocking[takeIndex].tracks[track].marks[mark].position += delta
            scene.blocking[takeIndex].tracks[track].marks[mark].via = scene.blocking[takeIndex].tracks[track]
                .marks[mark].via.map { $0 + delta }
        }
    }

    /// Turns an entity to `heading` at the first frame of a take.
    private static func turn(_ id: EntityID, to heading: Double, in scene: inout PrevisScene, take: TakeID) {
        guard let index = scene.entities.firstIndex(where: { $0.id == id }) else { return }
        guard let takeIndex = scene.blocking.firstIndex(where: { $0.id == take }),
              let track = scene.blocking[takeIndex].tracks.firstIndex(where: { $0.entityID == id }),
              let first = scene.blocking[takeIndex].tracks[track].marks.indices.min(by: {
                  scene.blocking[takeIndex].tracks[track].marks[$0].time
                      < scene.blocking[takeIndex].tracks[track].marks[$1].time
              })
        else {
            scene.entities[index].placement.heading = heading
            return
        }
        scene.blocking[takeIndex].tracks[track].marks[first].arriveHeading = heading
    }

    private static func problem(_ message: String) -> ShotsError {
        ShotsError.invalid([ShotsProblem(severity: .error, message: message)])
    }
}

/// Reads a brief out of a written description without a language model: the scene's own character and set-piece
/// names, and a small vocabulary of frame words. It is the offline path, and what a model's reading is checked
/// against; anything it can't read it leaves unset for the solver's defaults.
public enum BlockingReader {
    public static func brief(from text: String, scene: PrevisScene, newCharacters: [String] = []) -> BlockingBrief {
        let lower = text.lowercased()
        let pieces = scene.entities.filter { $0.setPiece != nil }.map(\.name)
        var names = scene.entities.filter { $0.setPiece == nil }.map(\.name) + newCharacters
        names = names.filter { name in lower.contains(name.lowercased()) }
        var seen: Set<String> = []
        names = names.filter { seen.insert($0.lowercased()).inserted }
        // In the order they are first named.
        names.sort { (lower.range(of: $0.lowercased())?.lowerBound ?? lower.endIndex)
            < (lower.range(of: $1.lowercased())?.lowerBound ?? lower.endIndex)
        }

        let clauses = lower.split(whereSeparator: { ".;\n|".contains($0) }).map(String.init)
        let general = clauses.filter { clause in !names.contains { clause.contains($0.lowercased()) } }
            .joined(separator: " ")
        let characters = names.map { name -> BlockingBrief.Character in
            let own = clauses.filter { clause in
                guard let range = clause.range(of: name.lowercased()) else { return false }
                // The clause is this character's when they are the first one it names.
                return !names.contains { other in
                    other != name && (clause.range(of: other.lowercased())?.lowerBound ?? clause.endIndex) < range
                        .lowerBound
                }
            }.joined(separator: " ")
            var character = BlockingBrief.Character(name: name)
            character.frameX = frameX(in: own)
            character.show = extent(in: own) ?? extent(in: general)
            if let (relation, piece) = place(in: own, pieces: pieces) {
                character.relation = relation
                character.piece = piece
            }
            character.facing = facing(in: own, names: names.filter { $0 != name })
            return character
        }
        return BlockingBrief(
            shot: shotName(in: text) ?? "New shot",
            plate: plateName(in: lower),
            characters: characters
        )
    }

    private static func frameX(in clause: String) -> Double? {
        let table: [(String, Double)] = [
            ("far left", 0.14), ("far right", 0.86), ("left of centre", 0.38), ("left of center", 0.38),
            ("right of centre", 0.62), ("right of center", 0.62), ("frame left", 0.27), ("frame-left", 0.27),
            ("left of frame", 0.27), ("left third", 0.27), ("on the left", 0.27), ("at left", 0.27),
            ("frame right", 0.73), ("frame-right", 0.73), ("right of frame", 0.73), ("right third", 0.73),
            ("on the right", 0.73), ("at right", 0.73), ("centre frame", 0.5), ("center frame", 0.5),
            ("frame centre", 0.5), ("frame center", 0.5), ("in the centre", 0.5), ("in the center", 0.5),
            ("centred", 0.5), ("centered", 0.5),
        ]
        return table.first { clause.contains($0.0) }?.1
    }

    private static func extent(in clause: String) -> BodyExtent? {
        let table: [(String, BodyExtent)] = [
            ("head to boots", .headToBoots), ("head-to-boots", .headToBoots), ("head to toe", .headToBoots),
            ("full shot", .headToBoots), ("full-length", .headToBoots), ("full length", .headToBoots),
            ("full figure", .headToBoots), ("wide shot", .headToBoots),
            ("knees up", .kneesUp), ("from the knees", .kneesUp), ("mid-thigh", .thighsUp), ("mid thigh", .thighsUp),
            ("medium-full", .thighsUp), ("medium full", .thighsUp), ("cowboy", .thighsUp),
            ("medium close", .chestUp), ("chest up", .chestUp), ("from the chest", .chestUp),
            ("extreme close", .face), ("close-up", .face), ("close up", .face), ("closeup", .face),
            ("waist up", .waistUp), ("waist-up", .waistUp), ("from the waist", .waistUp), ("medium", .waistUp),
            ("wide", .headToBoots),
        ]
        return table.first { clause.contains($0.0) }?.1
    }

    private static func place(
        in clause: String, pieces: [String]
    ) -> (BlockingBrief.Relation, String)? {
        let relations: [(String, BlockingBrief.Relation)] = [
            ("in front of the ", .inFrontOf), ("in front of ", .inFrontOf), ("behind the ", .behind),
            ("behind ", .behind), ("on top of the ", .on), ("standing on the ", .on), ("stands on the ", .on),
            ("on the ", .on), ("at the ", .inFrontOf), ("before the ", .inFrontOf),
        ]
        var best: (position: String.Index, relation: BlockingBrief.Relation, piece: String)?
        for (phrase, relation) in relations {
            var search = clause.startIndex ..< clause.endIndex
            while let found = clause.range(of: phrase, range: search) {
                let rest = clause[found.upperBound...]
                // The longest set-piece name that starts right there, so "dais table" beats "dais".
                let match = pieces.filter { rest.hasPrefix($0.lowercased()) }.max { $0.count < $1.count }
                if let match, best == nil || found.lowerBound < (best?.position ?? clause.endIndex) {
                    best = (found.lowerBound, relation, match)
                }
                search = found.upperBound ..< clause.endIndex
            }
        }
        return best.map { ($0.relation, $0.piece) }
    }

    private static func facing(in clause: String, names: [String]) -> BlockingBrief.Facing? {
        for lead in [
            "facing ",
            "faces ",
            "looking at ",
            "looks at ",
            "looking up at ",
            "looking down at ",
            "turned to ",
            "turned toward ",
            "toward ",
        ] {
            var search = clause.startIndex ..< clause.endIndex
            while let found = clause.range(of: lead, range: search) {
                let rest = clause[found.upperBound...]
                if let other = names.first(where: { rest.hasPrefix($0.lowercased()) }) { return .toward(other) }
                for (words, facing) in [
                    (["frame left", "left"], BlockingBrief.Facing.frameLeft),
                    (["frame right", "right"], .frameRight),
                    (["the camera", "camera", "us"], .camera), (["away"], .away),
                ] where words.contains(where: { rest.hasPrefix($0) }) {
                    return facing
                }
                search = found.upperBound ..< clause.endIndex
            }
        }
        if clause.contains("back to camera") || clause.contains("back to the camera") { return .away }
        if clause.contains("to camera") || clause.contains("toward the camera") { return .camera }
        return nil
    }

    /// A leading shot code such as "TS-01" or "FRC-10b".
    private static func shotName(in text: String) -> String? {
        let first = text.split(whereSeparator: { " \t|:,\n".contains($0) }).first.map(String.init) ?? ""
        let letters = first.prefix { $0.isLetter && $0.isUppercase }
        let rest = first.dropFirst(letters.count)
        let digits = rest.drop { $0 == "-" || $0 == "_" }
        guard (1 ... 5).contains(letters.count), let lead = digits.first, lead.isNumber, first.count <= 12 else {
            return nil
        }
        return first
    }

    /// "plate c", "plate B".
    private static func plateName(in lower: String) -> String? {
        guard let found = lower.range(of: "plate ") else { return nil }
        let word = lower[found.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return word.isEmpty ? nil : String(word)
    }
}
