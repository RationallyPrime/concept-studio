import Foundation

/// A centred grid in the formation's local XZ plane. Row 1 is at the front (−Z).
public struct Formation: Codable, Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var rowSpacing: Double
    public var columnSpacing: Double

    public static let dimensionRange = 1 ... 32

    public init(rows: Int, columns: Int, rowSpacing: Double, columnSpacing: Double) {
        self.rows = rows
        self.columns = columns
        self.rowSpacing = rowSpacing
        self.columnSpacing = columnSpacing
    }

    var isValid: Bool {
        Self.dimensionRange.contains(rows) && Self.dimensionRange.contains(columns)
            && rowSpacing.isFinite && rowSpacing > 0 && columnSpacing.isFinite && columnSpacing > 0
    }

    func contains(_ slot: FormationSlot) -> Bool {
        slot.row > 0 && slot.row <= rows && slot.column > 0 && slot.column <= columns
    }

    func offset(row: Int, column: Int) -> Vec3 {
        Vec3(
            (Double(column) - (Double(columns) + 1) / 2) * columnSpacing,
            0,
            (Double(row) - (Double(rows) + 1) / 2) * rowSpacing
        )
    }

    static func strideVariation(row: Int, column: Int) -> Double {
        Double((row * 31 + column * 17) % 11 - 5) * 0.008
    }
}

/// A named actor fills this one-based grid cell until the first mark on the actor's own track.
public struct FormationSlot: Codable, Sendable, Equatable, Hashable {
    public var formationID: EntityID
    public var row: Int
    public var column: Int

    public init(formationID: EntityID, row: Int, column: Int) {
        self.formationID = formationID
        self.row = row
        self.column = column
    }
}

/// One anonymous person inside a formation, kept separate for the pose pass.
public struct FormationPose: Sendable, Equatable {
    public var bounds: Box3
    public var keypoints: [Keypoint]

    public init(bounds: Box3, keypoints: [Keypoint] = []) {
        self.bounds = bounds
        self.keypoints = keypoints
    }
}

extension PrevisScene {
    func formationProblems(catalog: ContentCatalog) -> [ShotsProblem] {
        var slots: Set<FormationSlot> = []
        return entities.compactMap { entity in
            let person = catalog.asset(entity.assetID)?.rig == .person
            let message: String
            if let formation = entity.formation,
               !person || !formation.isValid || entity.formationSlot != nil {
                message = "Choose a person asset and a formation with 1–32 rows and columns and positive spacing."
            } else if let slot = entity.formationSlot {
                let formation = entities.first { $0.id == slot.formationID }?.formation
                if person, entity.attachment == nil, formation?.contains(slot) == true,
                   slots.insert(slot).inserted { return nil }
                message = "Choose an unoccupied formation slot for this person and clear any separate attachment."
            } else {
                return nil
            }
            return ShotsProblem(
                severity: .error, message: "“\(entity.name)”: \(message)", sceneID: id, entityID: entity.id
            )
        }
    }
}

extension EntityFrame {
    static func formed(
        _ entity: PrevisEntity,
        asset: AssetSpec,
        layout: Formation,
        state: EntityPose,
        named: [FormationSlot: EntityFrame]
    ) -> EntityFrame {
        var group = EntityFrame(
            id: entity.id, assetID: entity.assetID, name: entity.name, label: entity.label, isActor: true,
            position: state.position, heading: state.heading, gait: state.gait, speed: state.speed,
            distanceTravelled: state.distanceTravelled, joints: state.joints,
            bounds: Box3(min: state.position, max: state.position)
        )
        var bounds: Box3?
        for row in 1 ... layout.rows {
            for column in 1 ... layout.columns {
                let slot = FormationSlot(formationID: entity.id, row: row, column: column)
                if let member = named[slot] {
                    if member.formationID != nil { bounds = bounds?.union(member.bounds) ?? member.bounds }
                    continue
                }
                let offset = layout.offset(row: row, column: column) * entity.placement.scale
                var member = state
                member.position += state.frame.rotate(offset)
                member.distanceTravelled += Formation.strideVariation(row: row, column: column) * entity.placement.scale
                let body = Bodies.build(entity, asset: asset, state: member)
                bounds = bounds?.union(body.bounds) ?? body.bounds
                group.formationPoses.append(FormationPose(bounds: body.bounds, keypoints: body.keypoints))
                group.parts += body.parts.map {
                    PosedPart(
                        id: "\(row)-\(column)-\($0.id)",
                        shape: $0.shape,
                        transform: $0.transform,
                        color: $0.color
                    )
                }
            }
        }
        group.bounds = bounds ?? group.bounds
        return group
    }
}

private extension Box3 {
    func union(_ other: Box3) -> Box3 {
        Box3(
            min: Vec3(Swift.min(min.x, other.min.x), Swift.min(min.y, other.min.y), Swift.min(min.z, other.min.z)),
            max: Vec3(Swift.max(max.x, other.max.x), Swift.max(max.y, other.max.y), Swift.max(max.z, other.max.z))
        )
    }
}
