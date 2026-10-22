import ConceptCore
import Foundation

extension StudioSession {
    func useAsReference(image: ProjectImage, trigger: String) {
        chooseReference(trigger: trigger, from: image.url)
    }

    /// A mark invalidates confirmation, including automatic whole-target mappings.
    func markNotSure(id: String, note: String?) {
        guard !busy, var project else { return }
        do {
            if note != nil { try project.job.setMapping(nil, for: id) }
            try project.save()
            var state = projectState
            state.notSure[id] = note
            if !demoMode { try state.save(to: project.directory) }
            self.project = project
            projectState = state
            invalidateMappingUndo()
            message = note == nil ? "Not sure mark removed. Confirm the assignment when ready." :
                "Marked Not sure. This sample stays out of captioning and publishing."
        } catch { errorMessage = Self.describe(error) }
    }

    /// Save the entire batch once, and restore it with one Undo.
    func confirmMappings(ids: Set<String>, mapping: Job.Mapping?) {
        guard !busy, !editing, var project else { return }
        let eligible = project.images
            .filter { ids.contains($0.id) && (mapping == nil || projectState.notSure[$0.id] == nil) }
        let snapshots = eligible.map { MappingSnapshot(sampleID: $0.id, mapping: project.job.mapping(for: $0.id)) }
        guard !snapshots.isEmpty else { return }
        do {
            for image in eligible {
                try project.job.setMapping(mapping.flatMap(project.job.mappingIncludingWholeTargets), for: image.id)
            }
            try project.save()
            self.project = project
            mappingUndo.append(MappingUndo(snapshots: snapshots))
            message = "\(eligible.count) assignments \(mapping == nil ? "cleared" : "confirmed"). "
                + "Undo restores the batch."
        } catch { errorMessage = Self.describe(error) }
    }

    func confirmRemainingSinglePerson() {
        guard let project, project.job.concepts.count == 1,
              let concept = project.job.concepts.first, concept.targetConcept.isPersonIdentity else { return }
        let remaining = project.images
            .filter { project.job.mapping(for: $0.id) == nil && projectState.notSure[$0.id] == nil }
        let eligible = remaining.filter { analyses[$0.id]?.faces.count == 1 }
        mappingReviewExceptions = remaining.filter { analyses[$0.id]?.faces.count != 1 }.map(\.id)
        guard let locator = MappingLocatorDefaults.singleFaceClassNoun(for: concept, faceCount: 1) else { return }
        confirmMappings(ids: Set(eligible.map(\.id)), mapping: [concept.trigger: locator])
        message = "\(eligible.count) single-face samples confirmed. "
            + "\(mappingReviewExceptions.count) need review; Not sure samples were skipped."
    }

    static func nextUnconfirmed(
        after id: String,
        order: [String],
        confirmed: Set<String>,
        notSure: Set<String>
    ) -> String? {
        guard let index = order.firstIndex(of: id) else { return nil }
        return order.dropFirst(index + 1).first { !confirmed.contains($0) && !notSure.contains($0) }
    }

    func requestMappingSuggestions() async throws {
        guard let project else { return }
        let concepts = project.job.concepts.filter(\.targetConcept.requiresLocator)
        guard !concepts.isEmpty else { throw StudioError.message("Add a concept that needs a location first.") }
        let references = references.filter { key, _ in concepts.contains { $0.trigger == key } }
        guard concepts.filter(\.targetConcept.isPersonIdentity).allSatisfy({ references[$0.trigger] != nil }) else {
            throw StudioError.message("Choose a reference photo for each person in Concepts first.")
        }
        // Empty suggestions are completed results too: a reconnect resumes after them.
        let pending = project.images.filter {
            project.job.mapping(for: $0.id) == nil && projectState
                .notSure[$0.id] == nil && mappingProposals[$0.id] == nil
        }
        guard !pending.isEmpty
        else {
            message =
                "All remaining samples have suggestions. Review them or clear suggestions to request again."; return
        }
        let assistant = try StudioAssistant(endpoint: endpoint(), demo: demoMode)
        let batches = MappingRequests.batches(pending, size: mappingBatchSize)
        let limit = endpointKind == "vllm" ? min(max(concurrency, 1), 4) : 1
        let started = Date()
        var failures: [String] = []
        gpu.beginAppWork()
        defer { gpu.endAppWork() }
        try await withThrowingTaskGroup(of: MappingBatchResult.self) { group in
            var next = 0
            func submit(_ batch: [ProjectImage]) {
                group.addTask {
                    await assistant.mappingResult(images: batch, references: references, concepts: concepts)
                }
            }
            while next < min(limit, batches.count) {
                submit(batches[next]); next += 1
            }
            while let result = try await group.next() {
                // Drain cancelled children too: a sheet retry can already contain paid, completed results.
                var state = projectState
                for (id, suggestion) in result.suggestions {
                    state.mappingSuggestions[id] = Dictionary(uniqueKeysWithValues: suggestion.mapping.map { (
                        $0.key,
                        $0.value
                    ) })
                    state.mappingDescriptions[id] = suggestion.description
                }
                if !demoMode { try state.save(to: project.directory) }
                projectState = state
                failures += result.failures
                completed += result.suggestions.count + result.failures.count
                gpu.noteActivity()
                let remaining = pending.count - completed
                let seconds = completed == 0 ? 0 :
                    Int(Date().timeIntervalSince(started) / Double(completed) * Double(remaining))
                message = "Requesting assignments: \(completed) / \(pending.count) · "
                    + "about \(seconds / 60)m \(seconds % 60)s remaining"
                if next < batches.count, !Task.isCancelled { submit(batches[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        message = failures.isEmpty ? "Suggestions ready for \(completed) samples. Review and confirm the assignments." :
            "Saved \(completed - failures.count) suggestions. \(failures.count) failed; request again to resume."
        if !failures
            .isEmpty {
            throw StudioError
                .message("Assignments failed for: " + failures
                    .joined(separator: ", ") +
                    ". Completed suggestions were saved; request again to retry only these samples.")
        }
    }
}
