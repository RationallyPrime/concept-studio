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
        session.setAdultContent(true)
        session.privateDataset = false
        #expect(session.privateDataset)
        #expect(try Job.load(contentsOf: project.jobURL).adultContent)
        session.setAdultContent(false)
        #expect(session.privateDataset)
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
