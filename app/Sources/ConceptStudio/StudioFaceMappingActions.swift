import ConceptCore
import Foundation

extension StudioSession {
    var faceMappingPending: [ProjectImage] {
        project?.images.filter {
            project?.job.mapping(for: $0.id) == nil && projectState.notSure[$0.id] == nil
        } ?? []
    }

    var personReferences: [String: URL] {
        let triggers = Set(project?.job.concepts.filter(\.targetConcept.isPersonIdentity).map(\.trigger) ?? [])
        return references.filter { triggers.contains($0.key) }
    }

    var faceReviewIDs: [String] {
        let pending = Set(faceMappingPending.map(\.id))
        return mappingReviewExceptions.filter { pending.contains($0) }
    }

    func invalidateFaceRecognition(referencesChanged: Bool = false) {
        faceRecognitionGeneration += 1
        faceRecognitionResults = [:]
        mappingReviewExceptions = []
        if referencesChanged {
            referenceWarningTask?.cancel()
            referenceWarningTask = nil
            faceReferenceWarnings = [:]
        }
    }

    /// Reference checks use Vision only. They do not download the identity model.
    func inspectReferenceFaces() {
        referenceWarningTask?.cancel()
        let references = personReferences
        let generation = faceRecognitionGeneration
        referenceWarningTask = Task {
            var warnings: [String: [String]] = [:]
            for (trigger, url) in references.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                do { warnings[trigger] = try await faceRecognizer.referenceWarnings(url: url) } catch {
                    warnings[trigger] = [Self.describe(error)]
                }
            }
            guard !Task.isCancelled, generation == faceRecognitionGeneration else { return }
            faceReferenceWarnings = warnings
        }
    }

    func matchFacesOnMac() {
        guard !busy, !editing, let project else { return }
        let people = project.job.concepts.filter(\.targetConcept.isPersonIdentity)
        guard !people.isEmpty else { return }
        let references = personReferences
        guard people.allSatisfy({ references[$0.trigger] != nil }) else {
            errorMessage = "Choose a reference photo for each person in Concepts first."
            return
        }
        let pending = faceMappingPending
        guard !pending.isEmpty else { message = "Every included sample is confirmed or marked Not sure."; return }
        let generation = faceRecognitionGeneration
        perform("Matching faces on this Mac… First use downloads the 39 MB SFace model.") {
            self.inspectReferenceFaces()
            await self.referenceWarningTask?.value
            let batch = try await self.faceRecognizer.recognize(images: pending.map(\.url), references: references)
            try Task.checkCancellation()
            guard generation == self.faceRecognitionGeneration else { return }
            self.receiveFaceRecognition(batch)
            self.message = "\(batch.samples.count) samples checked on this Mac. "
                + "Review the scores, then confirm the assignments you want to keep."
        }
    }

    /// Recognition never changes a human-confirmed mapping or a held sample.
    func receiveFaceRecognition(_ batch: FaceRecognitionBatch) {
        let pending = Set(faceMappingPending.map(\.id))
        faceRecognitionResults.merge(batch.samples.filter { pending.contains($0.key) }) { _, new in new }
        faceReferenceWarnings = batch.referenceWarnings
        let singlePerson = project?.job.concepts.count == 1 ? project?.job.concepts.first : nil
        mappingReviewExceptions = faceMappingPending.filter { image in
            guard let concept = singlePerson, concept.targetConcept.isPersonIdentity else { return true }
            return faceRecognitionResults[image.id]?.singleMatch(for: concept.trigger) != true
        }.map(\.id)
    }

    func singleFaceSuggestion(for id: String) -> Job.Mapping? {
        guard let result = faceRecognitionResults[id], result.faces.count == 1,
              result.reviewReason == nil, let match = result.faces.first?.match,
              let concept = project?.job.concept(for: match.trigger),
              let locator = MappingLocatorDefaults.singleFaceClassNoun(for: concept, faceCount: 1) else { return nil }
        return [match.trigger: locator]
    }
}

extension FaceRecognitionResult {
    var mappingBand: FaceMatchBand {
        guard reviewReason == nil, faces.count == 1, let face = faces.first,
              face.reviewReason == nil, !face.scores.isEmpty else { return .needsReview }
        if face.match != nil { return .match }
        return face.scores.allSatisfy { $0.band == .noMatch } ? .noMatch : .needsReview
    }
}
