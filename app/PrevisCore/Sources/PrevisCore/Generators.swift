import Foundation

// Generators and helpers, CONTRACTS section 5.5. Skeletons until A3-A4: each throws `notImplemented`.

public enum CameraMoves { // several subjects act as one virtual subject at their midpoint
    public static func marks(
        _ moveID: String,
        scene: PrevisScene,
        shotID: ShotID,
        subjects: [EntityID],
        catalog: ContentCatalog
    ) throws -> (marks: [CameraMark], trackIDs: [EntityID]) {
        throw ShotsError.notImplemented("CameraMoves.marks")
    }
}

public enum ActionPaths { // speed nil keeps Blockout's timing; otherwise metres per second
    public static func marks(
        _ pathID: String,
        entity: PrevisEntity,
        startTime: Double,
        duration: Double,
        speed: Double?,
        catalog: ContentCatalog
    ) throws -> [ActorMark] {
        throw ShotsError.notImplemented("ActionPaths.marks")
    }
}

public enum Motions {
    public static func apply(
        _ motionID: String,
        to entity: PrevisEntity,
        track: Track?,
        at time: Double,
        catalog: ContentCatalog
    ) throws -> Track {
        throw ShotsError.notImplemented("Motions.apply")
    }

    /// Walk-and-talk: samples the upper-body motion at the travel track's times and keeps its legs.
    public static func overlay(_ motionID: String, onto track: Track, catalog: ContentCatalog) throws -> Track {
        throw ShotsError.notImplemented("Motions.overlay")
    }
}

public enum Framing {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case wide, full, medium, closeUp, twoShot, overShoulder, reverse, top, low, dutch
    }

    public static func cameraMark(
        _ kind: Kind,
        scene: PrevisScene,
        shotID: ShotID,
        subjects: [EntityID],
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> CameraMark {
        throw ShotsError.notImplemented("Framing.cameraMark")
    }
}

public enum Attachments {
    public static func attachment(
        child: EntityID,
        parent: EntityID,
        scene: PrevisScene,
        shotID: ShotID,
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> EntityAttachment {
        throw ShotsError.notImplemented("Attachments.attachment")
    }

    public static func placementWhenDetached(
        child: EntityID,
        scene: PrevisScene,
        shotID: ShotID,
        atFrame: Int,
        catalog: ContentCatalog
    ) throws -> Placement {
        throw ShotsError.notImplemented("Attachments.placementWhenDetached")
    }
}
