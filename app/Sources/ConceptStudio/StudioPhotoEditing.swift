import ConceptCore
import Foundation

extension StudioProject {
    func photoEditSource(for image: ProjectImage) throws -> URL {
        guard let record = mediaState.selections[image.id]?.photoEdit else { return image.url }
        guard !record.originalFile.isEmpty,
              URL(fileURLWithPath: record.originalFile).lastPathComponent == record.originalFile else {
            throw StudioError.message("The saved original photo path is invalid. Restore the project backup.")
        }
        let url = ProjectAppState.folder(in: directory).appendingPathComponent("originals", isDirectory: true)
            .appendingPathComponent(record.originalFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError.message("The original photo is missing. Restore it from your project backup.")
        }
        return url
    }
}

@MainActor
extension StudioSession {
    func approvePhotoEdits(id: String, adjustments: PhotoAdjustments) {
        guard !editing else { return }
        perform("Saving photo adjustments…") {
            try await self.savePhotoEdits(id: id, adjustments: adjustments)
            self.finishPhotoEdits()
        }
    }

    func applyPhotoOutliers(_ suggestions: [PhotoOutlier]) {
        guard !editing else { return }
        perform("Bringing selected outliers into line…") {
            defer { self.finishPhotoEdits() }
            for suggestion in suggestions {
                try Task.checkCancellation()
                let original = self.project?.mediaState.selections[suggestion.id]?.photoEdit?.adjustments
                    ?? PhotoAdjustments()
                try await self.savePhotoEdits(id: suggestion.id, adjustments: suggestion.applying(to: original))
                self.completed += 1
            }
        }
    }

    private func savePhotoEdits(id: String, adjustments: PhotoAdjustments) async throws {
        guard let project, let image = project.images.first(where: { $0.id == id }) else { return }
        let source = try project.photoEditSource(for: image)
        let bytes = try Data(contentsOf: source)
        let originalFile = project.mediaState.selections[id]?.photoEdit?.originalFile
            ?? VisionInspector.contentHash(bytes) + "." + source.pathExtension
        let originals = ProjectAppState.folder(in: project.directory).appendingPathComponent(
            "originals",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent(originalFile)
        if !FileManager.default.fileExists(atPath: original.path) { try AtomicFile.write(bytes, to: original) }
        let rendered = try await Task.detached {
            try MediaEditor.png(PhotoEditing.render(MediaEditor.orientedImage(bytes), adjustments: adjustments))
        }.value
        try Task.checkCancellation()
        let name = Sources.stem(of: id) + ".png"
        try self.project?.approveTarget(
            id: id, data: rendered, name: name,
            selection: MediaSelection(
                originalName: project.mediaState.selections[id]?.originalName ?? id,
                photoEdit: PhotoEditRecord(
                    originalFile: originalFile,
                    originalName: project.mediaState.selections[id]?.photoEdit?.originalName ?? image.id,
                    adjustments: adjustments
                )
            )
        )
        transferReviewState(from: id, to: name)
        selectedImageID = name
        invalidateMediaDraft(id: id)
    }

    func restoreOriginalPhoto(id: String) {
        guard !editing else { return }
        perform("Restoring the original photo…") {
            guard let project = self.project, let image = project.images.first(where: { $0.id == id }),
                  let record = project.mediaState.selections[id]?.photoEdit else { return }
            let original = try project.photoEditSource(for: image)
            try self.project?.approveTarget(
                id: id, data: Data(contentsOf: original), name: record.originalName,
                selection: MediaSelection(originalName: record.originalName)
            )
            self.transferReviewState(from: id, to: record.originalName)
            self.selectedImageID = record.originalName
            self.invalidateMediaDraft(id: id)
            self.finishPhotoEdits()
        }
    }

    private func finishPhotoEdits() {
        PhotoThumbnails.removeAll()
        startImageAnalysis()
        message = "Photo edits saved; originals are kept in the project. "
            + "Review the new targets and write fresh captions."
    }
}
