import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("mapping workflow")
@MainActor
struct MappingWorkflowTests {
    @Test func comparisonResultsKeepHumanMappingsAndIncludeNoMatchSamples() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "PERSON8"),
            Concept(trigger: "OTHER8"), Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
        let images = project.images
        #expect(images.count >= 3)
        let human = project.job.mappingIncludingWholeTargets(["PERSON8": "the person on the left"])
        for image in images {
            try project.job.setMapping(human, for: image.id)
        }
        try project.save()
        let savedBytes = try Data(contentsOf: project.jobURL)
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        let agreed = try #require(images.first?.id)
        let different = images[1].id
        let unmatched = images[2].id
        // Vision emits only confident matches. Its omitted sample must still receive a visible conclusion.
        session.receiveMappingSuggestions([
            agreed: ["PERSON8": "face 2, counted from left to right"],
            different: ["OTHER8": "face 1, counted from left to right"],
            "uncompared.mp4": ["PERSON8": "the person in the clip"],
        ], sampleIDs: images.map(\.id))
        let triggers: Set = ["PERSON8", "OTHER8"]
        func result(_ id: String) -> MappingSuggestionConclusion? {
            MappingSuggestionConclusion.compare(
                proposal: session.mappingProposals[id], confirmed: session.project?.job.mapping(for: id),
                locatorTriggers: triggers
            )
        }
        #expect(result(agreed) == .agrees)
        #expect(result(agreed)?.message
            .contains("agrees with your confirmation about which concepts are present") == true)
        #expect(session.mappingProposals[agreed]?["PERSON8"] == "face 2, counted from left to right")
        #expect(result(different) == .differs)
        #expect(session.mappingProposals[unmatched] == [:])
        #expect(result(unmatched) == .confirmedNoMatch)
        #expect(session.mappingProposals["uncompared.mp4"] == nil)
        for image in images {
            #expect(session.project?.job.mapping(for: image.id) == human)
        }
        #expect(try Data(contentsOf: project.jobURL) == savedBytes)
        #expect(try Job.load(contentsOf: project.jobURL) == project.job)
    }

    @Test func unconfirmedComparisonDistinguishesPendingEmptyAndSuggestedResults() {
        let triggers: Set = ["PERSON8"]
        #expect(MappingSuggestionConclusion.compare(proposal: nil, confirmed: nil, locatorTriggers: triggers) == nil)
        #expect(MappingSuggestionConclusion
            .compare(proposal: [:], confirmed: nil, locatorTriggers: triggers) == .noMatch)
        #expect(MappingSuggestionConclusion.compare(
            proposal: ["PERSON8": "face 1"], confirmed: nil, locatorTriggers: triggers
        ) == .suggested)
        #expect(MappingSuggestionConclusion.compare(
            proposal: ["STYLE8": "the whole image"], confirmed: ["PERSON8": "the person", "STYLE8": "the whole image"],
            locatorTriggers: triggers
        ) == .confirmedNoMatch)
    }

    @Test func acceptingSuggestionsIsExplicitUndoableAndLeavesExistingMappingsAlone() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let images = project.images
        project.job = try Job(concepts: [Concept(trigger: "PERSON8")])
        try project.job.setMapping(["PERSON8": "the person already confirmed"], for: images[2].id)
        try project.save()
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.mappingProposals = [
            images[0].id: ["PERSON8": "the person by the window"],
            images[1].id: ["PERSON8": "the person beside the gate"],
            images[2].id: ["PERSON8": "a different person"],
            "not-in-project.png": ["PERSON8": "the person"],
        ]

        #expect(session.validMappingSuggestionIDs == [images[0].id, images[1].id])
        session.acceptMappingSuggestions()
        #expect(session.project?.job.mapping(for: images[0].id)?["PERSON8"] == "the person by the window")
        #expect(session.project?.job.mapping(for: images[1].id)?["PERSON8"] == "the person beside the gate")
        #expect(session.project?.job.mapping(for: images[2].id)?["PERSON8"] == "the person already confirmed")
        #expect(session.canUndoMappingChange)
        #expect(session.mappingProposals[images[0].id] != nil)

        session.undoMappingChange()
        #expect(session.project?.job.mapping(for: images[0].id) == nil)
        #expect(session.project?.job.mapping(for: images[1].id) == nil)
        #expect(session.project?.job.mapping(for: images[2].id)?["PERSON8"] == "the person already confirmed")
        #expect(!session.canUndoMappingChange)
    }

    @Test func acceptingAllLeavesTheOpenDraftsSampleUnaccepted() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let images = project.images
        project.job = try Job(concepts: [Concept(trigger: "PERSON8")])
        try project.save()
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.mappingProposals = [
            images[0].id: ["PERSON8": "the person by the window"],
            images[1].id: ["PERSON8": "the person beside the gate"],
        ]

        session.acceptMappingSuggestions(except: [images[0].id])
        #expect(session.project?.job.mapping(for: images[0].id) == nil)
        #expect(session.mappingProposals[images[0].id] != nil)
        #expect(session.project?.job.mapping(for: images[1].id)?["PERSON8"] == "the person beside the gate")
        #expect(session.message.hasPrefix("1 suggestion accepted."))
    }

    @Test func manualConfirmationClearsTheSuggestionBeforeUnconfirming() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.receiveMappingSuggestions(
            [image.id: ["NORA7": "the suggested person"]], sampleIDs: [image.id]
        )

        session.confirmMapping(id: image.id, mapping: ["NORA7": "the person I selected"])
        #expect(session.mappingProposals[image.id] == nil)
        session.unconfirmMapping(id: image.id)
        session.acceptMappingSuggestions()

        #expect(session.project?.job.mapping(for: image.id) == nil)
        #expect(session.canUndoMappingChange)
        session.undoMappingChange()
        #expect(session.project?.job.mapping(for: image.id)?["NORA7"] == "the person I selected")
        #expect(session.mappingProposals[image.id] == nil)
    }

    @Test func aSingleFaceAllowsClassNounButMultipleFacesDoNot() throws {
        let woman = try Concept(trigger: "WOMAN8", classNoun: "woman")
        let object = try Concept(trigger: "MUG8", classNoun: "mug", targetConcept: .object)
        #expect(MappingLocatorDefaults.singleFaceClassNoun(for: woman, faceCount: 1) == "the woman")
        #expect(MappingLocatorDefaults.singleFaceClassNoun(for: woman, faceCount: 2) == nil)
        #expect(MappingLocatorDefaults.singleFaceClassNoun(for: woman, faceCount: nil) == nil)
        #expect(MappingLocatorDefaults.singleFaceClassNoun(for: object, faceCount: 1) == nil)
    }

    @Test func mediaCurationInvalidatesMappingUndo() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        let image = try #require(project.images.first)

        session.confirmMapping(id: image.id, mapping: ["NORA7": "the person beside the window"])
        #expect(session.canUndoMappingChange)
        session.includeMedia(image.id, included: false)
        #expect(!session.canUndoMappingChange)
        session.includeMedia(image.id, included: true)
        #expect(!session.canUndoMappingChange)

        session.confirmMapping(id: image.id, mapping: ["NORA7": "the person by the garden gate"])
        #expect(session.canUndoMappingChange)
        session.undoMediaCuration()
        #expect(!session.canUndoMappingChange)
        let analysis = session.analysisTask
        session.stopImageAnalysis()
        await analysis?.value
    }

    @Test(arguments: [TargetConcept.style, .motion])
    func approvingWholeTargetConceptKeepsAutomaticAssignment(_ category: TargetConcept) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "TARGET8", targetConcept: category)])
        let image = try #require(project.images.first)
        try project.approveTarget(
            id: image.id, data: Data(contentsOf: image.url), name: image.id,
            selection: MediaSelection(originalName: image.id)
        )
        let expected = project.job.wholeTargetMapping
        #expect(project.job.mapping(for: image.id) == expected)
        #expect(try Job.load(contentsOf: project.jobURL).mapping(for: image.id) == expected)
        #expect(project.job.unmapped([image.id]).isEmpty)
        try project.undoCuration()
        #expect(project.job.mapping(for: image.id) == expected)
    }

    @Test func approvedMixedTargetNeedsFreshLocatorConfirmation() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try mixedJob()
        let image = try #require(project.images.first)
        try project.job.setMapping(
            project.job.mappingIncludingWholeTargets(["PERSON8": "the person on the left"]), for: image.id
        )
        try project.approveTarget(
            id: image.id, data: Data(contentsOf: image.url), name: image.id,
            selection: MediaSelection(originalName: image.id)
        )
        #expect(project.job.mapping(for: image.id) == nil)
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        session.confirmMapping(id: image.id, mapping: ["PERSON8": "the person in the new crop"])
        let stored = try Job.load(contentsOf: project.jobURL)
        #expect(stored.mapping(for: image.id)?["PERSON8"] == "the person in the new crop")
        #expect(stored.mapping(for: image.id)?["STYLE8"] == project.job.wholeTargetMapping["STYLE8"])
        #expect(stored.mapping(for: image.id)?["MOVE8"] == project.job.wholeTargetMapping["MOVE8"])
    }

    @Test func importAndReincludeAssignAllWholeTargetConcepts() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
        let image = try #require(project.images.first)
        let name = try project.importData(Data(contentsOf: image.url), name: "added.png")
        #expect(project.job.mapping(for: name) == project.job.wholeTargetMapping)
        try project.setIncluded(image.id, false)
        try project.job.setMapping(nil, for: image.id)
        try project.setIncluded(image.id, true)
        #expect(project.job.mapping(for: image.id) == project.job.wholeTargetMapping)
        #expect(try Job.load(contentsOf: project.jobURL).mapping(for: image.id) == project.job.wholeTargetMapping)
    }

    @Test(arguments: TargetConcept.allCases)
    func navigationUsesTheConceptLocatorPolicy(_ category: TargetConcept) async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "TARGET8", targetConcept: category)])
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        #expect(session.journeySteps.contains(.mapping) == category.requiresLocator)
        session.step = .concepts
        session.next()
        #expect(session.step == (category.requiresLocator ? .mapping : .captioning))
        session.goBack()
        #expect(session.step == .concepts)
        session.step = .captioning
        session.goBack()
        #expect(session.step == (category.requiresLocator ? .mapping : .concepts))
    }

    @Test func addingOrChangingALocatorConceptInvalidatesAutomaticOnlyAssignments() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        try session.saveConcept(Concept(trigger: "STYLE8", targetConcept: .style), replacing: "NORA7")
        session.step = .mapping
        try session.saveConcept(Concept(trigger: "MOVE8", targetConcept: .motion), replacing: nil)
        #expect(session.step == .captioning)
        #expect(session.unmappedCount == 0)
        try session.saveConcept(Concept(trigger: "OBJECT8", targetConcept: .object), replacing: "STYLE8")
        #expect(session.unmappedCount == project.images.count)
        #expect(session.journeySteps.contains(.mapping))
        let id = try #require(session.project?.images.first?.id)
        session.confirmMapping(id: id, mapping: ["OBJECT8": "the mug in the foreground"])
        #expect(session.project?.job.mapping(for: id)?["MOVE8"] != nil)
        try session.saveConcept(Concept(trigger: "PERSON8"), replacing: nil)
        #expect(session.unmappedCount == project.images.count)
        project = try #require(session.project)
        #expect(try Job.load(contentsOf: project.jobURL) == project.job)
    }

    @Test func confirmingConceptsSavesAndMovesToTheApplicableNextStep() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        try session.saveConcept(Concept(trigger: "STYLE8", targetConcept: .style), replacing: "NORA7")
        session.step = .concepts
        session.confirmConcepts()
        #expect(session.errorMessage == nil)
        #expect(session.step == .captioning)
        #expect(try Job.load(contentsOf: project.jobURL) == session.project?.job)
        try FileManager.default.removeItem(at: project.jobURL)
        try FileManager.default.createDirectory(at: project.jobURL, withIntermediateDirectories: false)
        session.step = .concepts
        session.confirmConcepts()
        #expect(session.errorMessage != nil)
        #expect(session.step == .concepts)
    }

    @Test func fileBackedApprovalUsesTheSameMappingAndUndoPath() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "STYLE8", targetConcept: .style)])
        let image = try #require(project.images.first)
        let source = project.directory.appendingPathComponent("source.png")
        try FileManager.default.copyItem(at: image.url, to: source)
        let bytes = try Data(contentsOf: source)
        try project.approveTarget(
            id: image.id, sourceFile: source, name: image.id, selection: MediaSelection(originalName: image.id)
        )
        #expect(try Data(contentsOf: image.url) == bytes)
        #expect(project.job.mapping(for: image.id) == project.job.wholeTargetMapping)
        try project.undoCuration()
        #expect(try Data(contentsOf: image.url) == bytes)
    }

    private func mixedJob() throws -> Job {
        try Job(concepts: [
            Concept(trigger: "STYLE8", targetConcept: .style), Concept(trigger: "PERSON8"),
            Concept(trigger: "MOVE8", targetConcept: .motion),
        ])
    }
}

@Suite("mapping friction fixes")
@MainActor
struct MappingFrictionTests {
    @Test func forwardNavigationNeverWrapsAndSkipsUncertain() {
        #expect(StudioSession
            .nextUnconfirmed(after: "b", order: ["a", "b", "c", "d"], confirmed: [], notSure: ["c"]) == "d")
        #expect(StudioSession
            .nextUnconfirmed(after: "d", order: ["a", "b", "c", "d"], confirmed: [], notSure: []) == nil)
    }

    @Test func batchConfirmationSkipsUncertainAndUndoRestoresAll() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job = try Job(concepts: [Concept(trigger: "PERSON8", classNoun: "woman")])
        try project.save()
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        let ids = Array(project.images.prefix(4).map(\.id))
        session.markNotSure(id: ids[1], note: "Face hidden")
        session.analyses[ids[0]] = ImageAnalysis(faces: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        session.analyses[ids[1]] = session.analyses[ids[0]]
        session.analyses[ids[2]] = ImageAnalysis(faces: [])
        session.analyses[ids[3]] = ImageAnalysis(faces: [CGRect.zero, CGRect.zero])
        session.confirmRemainingSinglePerson()
        #expect(session.project?.job.mapping(for: ids[0])?["PERSON8"] == "the woman")
        #expect(session.project?.job.mapping(for: ids[1]) == nil)
        #expect(!session.mappingReviewExceptions.contains(ids[1]))
        #expect(session.mappingReviewExceptions.contains(ids[2]))
        #expect(session.mappingReviewExceptions.contains(ids[3]))
        #expect(ProjectAppState.load(from: project.directory).notSure[ids[1]] == "Face hidden")
        session.undoMappingChange()
        #expect(session.project?.job.mapping(for: ids[0]) == nil)
        session.confirmMappings(ids: Set(ids), mapping: ["PERSON8": "the woman"])
        #expect(session.project?.job.mapping(for: ids[1]) == nil)
        #expect(session.project?.job.mapping(for: ids[3]) != nil)
        session.undoMappingChange()
        #expect(ids.allSatisfy { session.project?.job.mapping(for: $0) == nil })
    }

    @Test func resumeCachePersistsAndNotSureInvalidatesConfirmation() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        let id = try #require(project.images.first?.id)
        session.mappingProposals[id] = [:]
        session.mappingDescriptions[id] = "No match"
        let reloaded = ProjectAppState.load(from: project.directory)
        #expect(reloaded.mappingSuggestions[id] == [:])
        #expect(reloaded.mappingDescriptions[id] == "No match")
        session.markNotSure(id: id, note: "")
        #expect(session.project?.job.mapping(for: id) == nil)
        #expect(session.validMappingSuggestionIDs.isEmpty)
    }
}

extension MappingFrictionTests {
    @Test func referenceReplacementWaitsForActiveWork() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = StudioSession(preferences: defaults.defaults, secrets: MemorySecretStore())
        session.project = project
        let image = try #require(project.images.first)
        let reference = project.referenceURL(for: "NORA7")
        session.chooseReference(trigger: "NORA7", from: image.url)
        let before = try Data(contentsOf: reference)
        let thumbnailKey = PhotoThumbnails.Key(url: reference, pixels: 128)
        _ = await PhotoThumbnails.load(thumbnailKey)
        let revision = session.referenceRevision
        let other = project.images[1]
        session.mappingProposals[image.id] = ["NORA7": "the person"]
        session.busy = true
        session.useAsReference(image: other, trigger: "NORA7")
        #expect(try Data(contentsOf: reference) == before)
        #expect(session.mappingProposals[image.id] != nil)
        session.busy = false
        session.editing = true
        session.chooseReference(trigger: "NORA7", from: other.url)
        #expect(try Data(contentsOf: reference) == before)
        session.editing = false
        session.useAsReference(image: other, trigger: "NORA7")
        #expect(try Data(contentsOf: reference) != before)
        #expect(PhotoThumbnails.cached(thumbnailKey) == nil)
        #expect(session.referenceRevision == revision + 1)
        #expect(session.mappingProposals.isEmpty)
    }
}
