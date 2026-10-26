import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Shots workspace navigation")
@MainActor
struct ShotsWorkspaceTests {
    @Test(arguments: [StudioStep.images, .concepts, .pods])
    func switchingWorkspacesPreservesConceptFreeProject(step: StudioStep) throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-workspace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeTestSession(preferences: defaults.defaults)
        session.project = try StudioProject.create(at: directory)
        session.step = step
        let jobURL = directory.appendingPathComponent("job.yaml")
        let originalJob = try Data(contentsOf: jobURL)

        #expect(session.project?.job.concepts.isEmpty == true)
        #expect(session.workspace == .training)
        session.workspace = .shots
        #expect(session.step == step)
        session.workspace = .training
        #expect(session.step == step)
        #expect(try Data(contentsOf: jobURL) == originalJob)
    }
}
