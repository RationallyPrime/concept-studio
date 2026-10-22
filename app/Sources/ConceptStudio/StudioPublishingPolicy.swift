import ConceptCore
import Foundation

extension StudioProject {
    /// One selection shared by Hub publication and the direct training snapshot.
    func publishingImages(state: ProjectAppState) -> [ProjectImage] {
        images.filter {
            state.notSure[$0.id] == nil && (state.includeUncaptioned || !$0.caption.isBlank)
        }
    }
}

extension StudioSession {
    func setAdultContent(_ enabled: Bool) {
        guard !busy, !editing, var updated = project else { return }
        do {
            updated.job.adultContent = enabled
            try updated.save()
            project = updated
            if enabled { updateProjectState { $0.dataset.isPrivate = true } }
        } catch { errorMessage = Self.describe(error) }
    }

    var publishingImages: [ProjectImage] {
        project?.publishingImages(state: projectState) ?? []
    }

    var uncaptionedPublishingImages: [ProjectImage] {
        project?.images.filter { projectState.notSure[$0.id] == nil && $0.caption.isBlank } ?? []
    }
}
