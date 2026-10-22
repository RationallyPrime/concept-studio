import ConceptCore
import Foundation

/// The app stores masks beside project state; published metadata associates each mask with its target.
enum TrainingMasks {
    static let metadataColumn = "training_mask"

    static func source(for image: ProjectImage, project: StudioProject) throws -> URL? {
        try TrainingLossMasks.validURL(for: image.url, in: project.directory)
    }

    static func publishedPath(for id: String) -> String {
        "training_masks/" + Sources.stem(of: id) + ".png"
    }

    /// Flat staging keeps the existing upload contract; pull_dataset installs the native mask directory.
    static func uploadName(for id: String) -> String {
        "training-mask-" + VisionInspector.contentHash(Data(id.utf8)) + ".png"
    }
}
