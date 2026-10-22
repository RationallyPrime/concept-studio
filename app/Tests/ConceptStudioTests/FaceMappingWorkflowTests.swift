import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Local face Mapping workflow")
@MainActor
struct FaceMappingWorkflowTests {
    private func result(_ band: FaceMatchBand, score: Float = 0.5, faces: Int = 1) -> FaceRecognitionResult {
        FaceRecognitionResult(faces: Array(repeating: RecognizedFace(
            box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            scores: [FaceIdentityScore(trigger: "PERSON8", similarity: score, band: band)]
        ), count: faces))
    }

    @Test func bulkConfirmationUsesIdentityBandAndPreservesHumanDecisions() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "PERSON8", classNoun: "woman")])
        let ids = Array(project.images.prefix(8).map(\.id))
        try project.job.setMapping(["PERSON8": "the woman I confirmed"], for: ids[6])
        try project.save()
        let session = makeTestSession()
        session.project = project
        session.markNotSure(id: ids[5], note: "Hidden face")
        session.receiveFaceRecognition(FaceRecognitionBatch(samples: [
            ids[0]: result(.match), ids[1]: result(.needsReview, score: 0.36),
            ids[2]: result(.noMatch, score: 0.2), ids[3]: result(.match, faces: 2),
            ids[4]: FaceRecognitionResult(reviewReason: "No face detected"),
            ids[5]: result(.match), ids[6]: result(.match), ids[7]: result(.match),
        ], referenceWarnings: [:]))
        #expect(session.faceRecognitionResults[ids[5]] == nil)
        #expect(session.faceRecognitionResults[ids[6]] == nil)
        #expect(session.project?.job.mapping(for: ids[0]) == nil)
        #expect(session.singleFaceSuggestion(for: ids[0])? ["PERSON8"] == "the woman")
        session.confirmRemainingSinglePerson(except: [ids[7]])
        #expect(session.project?.job.mapping(for: ids[0])? ["PERSON8"] == "the woman")
        for id in ids[1 ... 5] + [ids[7]] {
            #expect(session.project?.job.mapping(for: id) == nil)
        }
        #expect(session.project?.job.mapping(for: ids[6])? ["PERSON8"] == "the woman I confirmed")
        #expect(!session.faceReviewIDs.contains(ids[5]))
        #expect(session.faceReviewIDs.contains(ids[7]))
        session.undoMappingChange()
        #expect(session.project?.job.mapping(for: ids[0]) == nil)
    }

    @Test func faceResultsExpireWithReferencesMediaAndProjects() async throws {
        let session = makeTestSession()
        let first = try await makeDemoProject()
        let second = try await makeDemoProject()
        defer {
            session.referenceWarningTask?.cancel()
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        session.project = first
        let image = try #require(first.images.first)
        session.faceRecognitionResults[image.id] = result(.match)
        session.invalidateMediaDraft(id: image.id)
        #expect(session.faceRecognitionResults.isEmpty)
        session.faceRecognitionResults[image.id] = result(.match)
        session.chooseReference(trigger: "NORA7", from: image.url)
        #expect(session.faceRecognitionResults.isEmpty)
        await session.referenceWarningTask?.value
        #expect(session.faceReferenceWarnings["NORA7"] != nil)
        session.faceRecognitionResults[image.id] = result(.match)
        session.project = second
        #expect(session.faceRecognitionResults.isEmpty)
        #expect(session.faceReferenceWarnings.isEmpty)
    }

    @Test func exclusionAndNullStaySeparateFromConfirmedPresence() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "PERSON8"), Concept(trigger: "OTHER8")])
        let held = project.images[0].id, absent = project.images[1].id
        try project.job.setMapping(nil, for: held)
        try project.job.setMapping(["OTHER8": "the other person"], for: absent)
        try project.setIncluded(held, false)
        let reopened = try await StudioProject.open(at: project.directory)
        #expect(reopened.excludedImages.contains { $0.id == held })
        #expect(reopened.job.mapping(for: held) == nil)
        #expect(reopened.job.unmapped([held]) == [held])
        #expect(reopened.job.mapping(for: absent) != nil)
        #expect(reopened.job.mapping(for: absent)? ["PERSON8"] == nil)
        #expect(reopened.job.mapping(for: absent)? ["OTHER8"] != nil)
        #expect(throws: (any Error).self) { try project.job.setMapping([:], for: held) }
    }

    @Test(arguments: ["single", "multiple-references", "multiple-concepts", "ordinary-name", "canonical-present"])
    func referenceRecoveryOnlyUsesAnUnambiguousOldHexFilename(_ scenario: String) async throws {
        let directory = temporaryTestDirectory("reference-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        project.job = try Job(concepts: [Concept(trigger: "NEW8")])
        let old = scenario == "ordinary-name"
            ? directory.appendingPathComponent("references/photo.png") : project.referenceURL(for: "OLD8")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try MediaEditor.png(MediaFixtures.image())
        try bytes.write(to: old)
        if scenario == "multiple-references" { try bytes.write(to: project.referenceURL(for: "OTHER8")) }
        if scenario == "multiple-concepts" { try project.job.concepts.append(Concept(trigger: "OTHER8")) }
        let canonical = project.referenceURL(for: "NEW8")
        if scenario == "canonical-present" { try Data("already selected".utf8).write(to: canonical) }
        try project.save()
        let reopened = try await StudioProject.open(at: directory)
        #expect(reopened.referenceURL(for: "NEW8") == canonical)
        if scenario == "single" {
            #expect(try Data(contentsOf: canonical) == bytes)
            #expect(!FileManager.default.fileExists(atPath: old.path))
        } else {
            #expect(FileManager.default.fileExists(atPath: old.path))
            if scenario == "canonical-present" {
                #expect(try Data(contentsOf: canonical) == Data("already selected".utf8))
            } else { #expect(!FileManager.default.fileExists(atPath: canonical.path)) }
        }
    }
}
