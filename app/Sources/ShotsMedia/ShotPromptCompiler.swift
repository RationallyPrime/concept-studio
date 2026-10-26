import ConceptCore
import Foundation
import PrevisCore

/// The facts a shot's H3 prompt is written from. Fields beyond these land with the compiler in B5.
public struct PromptFacts: Codable, Sendable, Equatable {
    public var sceneRevision: Int
    public var frameCount: Int
    public var canvas: ShotCanvas

    public init(sceneRevision: Int, frameCount: Int, canvas: ShotCanvas) {
        self.sceneRevision = sceneRevision
        self.frameCount = frameCount
        self.canvas = canvas
    }
}

/// Turns a shot into an H3 prompt in MiniMax's FL2VA structure. Lands in B5.
public enum ShotPromptCompiler {
    public static func facts(scene: PrevisScene, shotID: ShotID, catalog: ContentCatalog) throws -> PromptFacts {
        throw ShotsError.notImplemented("Prompt facts")
    }

    /// Deterministic and offline.
    public static func template(_ facts: PromptFacts) -> ShotPrompt {
        ShotPrompt(sections: [], text: "", sceneRevision: facts.sceneRevision, writtenBy: "template")
    }

    public static func write(_ facts: PromptFacts, endpoint: ResolvedEndpoint) async throws -> ShotPrompt {
        throw ShotsError.notImplemented("Model-written prompts")
    }
}
