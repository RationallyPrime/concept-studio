import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Publishing and adult project policy")
struct PublishingPolicyTests {
    @Test func hubAndDirectUploadUseTheSameSelection() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        for image in project.images {
            try await project.saveCaption(id: image.id, text: "A caption.", final: false)
        }
        let blank = project.images[0].id
        let unsure = project.images[1].id
        try await project.saveCaption(id: blank, text: "", final: false)
        var state = ProjectAppState()
        state.notSure[unsure] = "Review subject"
        try state.save(to: project.directory)
        let selected = project.publishingImages(state: state)
        #expect(!selected.contains { $0.id == blank || $0.id == unsure })
        let operations = try await ProjectPublisher.operations(for: project, state: state)
        #expect(!operations.contains { $0.path == blank || $0.path == unsure })
        let snapshot = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        defer { snapshot.remove() }
        #expect(snapshot.itemCount == selected.count)
        #expect(!snapshot.files.contains { $0.name == blank || $0.name == unsure })
        state.includeUncaptioned = true
        try state.save(to: project.directory)
        let included = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        defer { included.remove() }
        #expect(included.files.contains { $0.name == blank })
        #expect(!included.files.contains { $0.name == unsure })
    }

    @MainActor @Test func adultSwitchPersistsAndLocksPrivatePublishing() async throws {
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let session = try StudioSession(preferences: temporaryPreferences().0, secrets: MemorySecretStore())
        session.project = project
        session.privateDataset = false
        session.trainingOutputPrivate = false
        session.setAdultContent(true)
        session.privateDataset = false
        session.trainingOutputPrivate = false
        #expect(session.privateDataset)
        #expect(session.trainingOutputPrivate)
        #expect(session.trainingOutput.isPrivate)
        #expect(ProjectAppState.load(from: project.directory).trainingOutput.isPrivate)
        #expect(try Job.load(contentsOf: project.jobURL).adultContent)
        session.setAdultContent(false)
        #expect(session.privateDataset)
        #expect(session.trainingOutputPrivate)
    }

    @MainActor @Test func adultProjectLoadedWithPublicOutputUsesPrivateTrainingDestination() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job.adultContent = true
        let session = makeTestSession()
        session.project = project
        session.projectState.trainingOutput = HubDestination(repo: "owner/model", isPrivate: false)
        #expect(session.trainingOutput == HubDestination(repo: "owner/model", isPrivate: true))
    }

    @MainActor @Test(arguments: [false, true])
    func notSureFollowsApprovedTargetAndUndo(video: Bool) async throws {
        let session = makeTestSession()
        session.project = try await makeDemoProject()
        let directory = try #require(session.project?.directory)
        defer { session.stopImageAnalysis(); try? FileManager.default.removeItem(at: directory) }
        let oldID = video ? "clip.mov" : "garden.jpg"
        let newID = video ? "clip.mp4" : "garden.png"
        if video {
            let original = directory.appendingPathComponent(oldID)
            try await MediaFixtures.video(at: original, times: (0 ..< 50).map { Double($0) / 24 })
            var project = try #require(session.project)
            try await project.importFiles([original])
            session.project = project
        }
        session.markNotSure(id: oldID, note: "Check identity")
        if video {
            session.approveVideoSegment(id: oldID, startFrame: 2, frameCount: 22, longEdge: 512, format: .h3)
        } else {
            session.approveCrop(id: oldID, rectangle: CGRect(x: 0, y: 0, width: 0.8, height: 0.8))
        }
        await session.task?.value
        #expect(session.errorMessage == nil)
        #expect(session.project?.images.contains { $0.id == newID } == true)
        #expect(session.projectState.notSure == [newID: "Check identity"])
        #expect(ProjectAppState.load(from: directory).notSure == session.projectState.notSure)
        session.updateProjectState { $0.includeUncaptioned = true }
        #expect(!session.publishingImages.contains { $0.id == newID })
        let snapshot = try await LocalTrainingDataset.prepare(projectFolder: directory)
        defer { snapshot.remove() }
        #expect(!snapshot.files.contains { $0.name == newID })
        session.undoMediaCuration()
        #expect(session.errorMessage == nil)
        #expect(session.project?.images.contains { $0.id == oldID } == true)
        #expect(session.projectState.notSure == [oldID: "Check identity"])
        #expect(ProjectAppState.load(from: directory).notSure == session.projectState.notSure)
        #expect(!session.publishingImages.contains { $0.id == oldID })
    }

    @MainActor @Test func failedWorkClearsProgressAndReleasesGPUActivity() async throws {
        let session = try StudioSession(preferences: temporaryPreferences().0, secrets: MemorySecretStore())
        session.perform("Downloading dataset images and clips…") { throw StudioError.message("Connection dropped") }
        await session.task?.value
        #expect(session.message.isEmpty)
        #expect(session.errorMessage == "Connection dropped")
        #expect(session.gpu.appWorkInFlight == 0)
    }
}
