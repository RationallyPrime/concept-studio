import ConceptCore
import Foundation

@MainActor
extension StudioSession {
    /// The size upscaled results are made at, from the project's training model.
    var upscaleTarget: UpscaleTarget {
        UpscaleTarget(row: gpu.effectiveModelRow)
    }

    /// Included samples below the target size, the ones the upscale sheet selects first.
    var upscaleSuggestions: [String] {
        (project?.images ?? []).filter { upscaleTarget.isBelow(analyses[$0.id]) }.map(\.id)
    }

    var pendingUpscales: [PendingUpscale] {
        project?.mediaState.pendingUpscales ?? []
    }

    func upscaleRecord(for id: String) -> UpscaleRecord? {
        project?.mediaState.upscaled[id]
    }

    /// Sends the chosen included samples to the cloud GPU and keeps each result beside its original until the
    /// person keeps or discards it. A sample with a result already waiting is sent again only if chosen again.
    func upscale(_ ids: [String], model: UpscaleModel) {
        guard let project, !ids.isEmpty else { return }
        let target = upscaleTarget
        let inputs = ids.compactMap { id in
            project.images.first(where: { $0.id == id }).map { UpscaleInput(sampleID: id, file: $0.url) }
        }
        perform("Upscaling \(inputs.count) on the cloud GPU…") {
            let runFolder = project.upscaledDirectory.appendingPathComponent(UUID().uuidString.lowercased())
            let outcome = try await self.gpu.upscale(inputs, model: model, target: target, into: runFolder) {
                self.message = $0
            }
            try Task.checkCancellation()
            guard self.project?.directory == project.directory else { return }
            let created = Date()
            for (sampleID, url) in outcome.results.sorted(by: { $0.key < $1.key }) {
                let previous = self.project?.mediaState.pendingUpscales.first { $0.sourceID == sampleID }
                if let previous, let directory = self.project?.directory {
                    try? FileManager.default.removeItem(at: previous.resultURL(in: directory))
                }
                self.project?.mediaState.pendingUpscales.removeAll { $0.sourceID == sampleID }
                self.project?.mediaState.pendingUpscales.append(PendingUpscale(
                    sourceID: sampleID,
                    resultPath: "upscaled/\(runFolder.lastPathComponent)/\(url.lastPathComponent)",
                    model: model, shortSide: target.shortSide, created: created
                ))
            }
            try self.project?.save()
            self.message = Self.upscaleSummary(outcome)
        }
    }

    static func upscaleSummary(_ outcome: UpscaleOutcome) -> String {
        var text = outcome.results.isEmpty ? "No upscaled media came back." :
            "\(outcome.results.count) upscaled. Compare each with its original, then keep or discard it."
        for (id, reason) in outcome.failures.sorted(by: { $0.key < $1.key }) {
            text += " \(id) was not upscaled: \(reason)."
        }
        return text
    }

    func keepUpscale(_ sourceID: String) {
        guard !busy, !editing,
              let pending = pendingUpscales.first(where: { $0.sourceID == sourceID }) else { return }
        if let image = project?.images.first(where: { $0.id == sourceID }), hasUnsavedCaption(for: image) {
            errorMessage = "Save or discard the caption edits of \(sourceID) before replacing it."
            return
        }
        do {
            let newID = project?.upscaledName(
                for: sourceID, resultExtension: URL(fileURLWithPath: pending.resultPath).pathExtension.lowercased()
            )
            try project?.keepUpscale(pending)
            if let newID { transferReviewState(from: sourceID, to: newID) }
            invalidateMediaDraft(id: sourceID)
            afterUpscaleChange()
            message = "Upscaled version kept. Its original is saved in the project; Put back original restores it."
        } catch { errorMessage = Self.describe(error) }
    }

    func keepAllUpscales() {
        for pending in pendingUpscales where project?.isIncluded(pending.sourceID) == true {
            keepUpscale(pending.sourceID)
            if errorMessage != nil { return }
        }
    }

    func discardUpscale(_ sourceID: String) {
        guard !busy, !editing else { return }
        do {
            try project?.discardUpscale(sourceID)
            message = "Upscaled version discarded. The original is unchanged."
        } catch { errorMessage = Self.describe(error) }
    }

    func revertUpscale(_ id: String) {
        guard !busy, !editing else { return }
        if let image = project?.allMedia.first(where: { $0.id == id }), hasUnsavedCaption(for: image) {
            errorMessage = "Save or discard the caption edits of \(id) before putting its original back."
            return
        }
        do {
            let original = upscaleRecord(for: id)?.originalID
            try project?.revertUpscale(id)
            if let original { transferReviewState(from: id, to: original) }
            invalidateMediaDraft(id: id)
            afterUpscaleChange()
            selectedImageID = original
            message = "Original put back. The upscaled version is kept in the project's edits folder."
        } catch { errorMessage = Self.describe(error) }
    }

    private func afterUpscaleChange() {
        invalidateMappingUndo()
        PhotoThumbnails.removeAll()
        startImageAnalysis()
    }
}
