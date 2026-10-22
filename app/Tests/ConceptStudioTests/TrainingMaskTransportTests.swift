import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Training masks and augmentation transport")
@MainActor
struct TrainingMaskTransportTests {
    @Test func publishedAndUploadedMasksStayPairedAndStaleMasksStayHome() async throws {
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let image = try #require(project.images.first)
        try await project.saveCaption(id: image.id, text: "NORA7 standing outdoors.", final: false)
        try TrainingLossMasks.save(
            rectangles: [CGRect(x: 0, y: 0, width: 0.25, height: 1)], imageURL: image.url, project: project
        )
        let mask = try #require(try TrainingMasks.source(for: image, project: project))
        let operations = try await ProjectPublisher.operations(for: project)
        let maskPath = TrainingMasks.publishedPath(for: image.id)
        #expect(operations.contains { $0.path == maskPath })
        let metadata = try #require(operations.first { $0.path == "metadata.jsonl" })
        guard case let .add(_, data) = metadata else { Issue.record("Expected serialized metadata"); return }
        let rows = try ImageFolderMetadata.parse(data)
        #expect(rows.first { $0.fileName == image.id }?.extra[TrainingMasks.metadataColumn]?.stringValue == maskPath)
        #expect(!rows.contains { $0.fileName == maskPath })
        let snapshot = try await LocalTrainingDataset.prepare(projectFolder: project.directory)
        defer { snapshot.remove() }
        let stagedMask = try #require(snapshot.files.first { $0.name == TrainingMasks.uploadName(for: image.id) })
        #expect(try Data(contentsOf: stagedMask.url) == Data(contentsOf: mask))
        let stagedRows = try ImageFolderMetadata
            .parse(Data(contentsOf: snapshot.folder.appendingPathComponent("metadata.jsonl")))
        #expect(stagedRows.first { $0.fileName == image.id }?.extra[TrainingMasks.metadataColumn]?
            .stringValue == stagedMask.name)
        if let path = ProcessInfo.processInfo.environment["CONCEPTSTUDIO_MASK_TRANSPORT_FIXTURE"] {
            try FileManager.default.copyItem(at: snapshot.folder, to: URL(fileURLWithPath: path))
        }
        try AtomicFile.write(MediaEditor.png(MediaFixtures.image(width: 256, height: 256)), to: image.url)
        #expect(try TrainingMasks.source(for: image, project: project) == nil)
        let republish = try await ProjectPublisher.operations(for: project, previousRows: rows, remotePaths: [maskPath])
        #expect(republish.contains { operation in
            if case let .delete(path) = operation { return path == maskPath }
            return false
        })
    }

    @Test func augmentationDefaultsOffAndUsesOnlySupportedProjectChoices() {
        let workspace = GPUWorkspace(demoMode: true)
        #expect(workspace.trainingAugmentation == .none)
        workspace.trainingAugmentation = .square
        workspace.squareAugmentationAllowed = false
        #expect(workspace.effectiveAugmentation == .none)
        workspace.trainingAugmentation = .horizontal
        #expect(workspace.effectiveAugmentation == .horizontal)
        let params = workspace.trainingParams(
            dataset: "test",
            inputFacts: (profile: "plain", triggers: "PERSON8", video: false)
        )
        #expect(params["augmentation"] == .string("horizontal"))
        workspace.trainingAugmentation = .square
        workspace.squareAugmentationAllowed = true
        #expect(workspace.effectiveAugmentation == .square)
        workspace.datasetContainsVideo = true
        #expect(workspace.effectiveAugmentation == .none)
        workspace.trainer = "musubi"
        #expect(!workspace.effectiveModelRow.trainingTransforms.lossMask)
        #expect(workspace.effectiveAugmentation == .none)
    }
}
