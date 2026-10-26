import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("Shots workspace entry")
@MainActor
struct ShotsWorkspaceEntryTests {
    @Test func noProjectCannotEnterShots() {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let session = makeTestSession(preferences: defaults.defaults)
        session.showShots()
        #expect(session.workspace == .training)
    }

    @Test(arguments: [StudioStep.images, .concepts, .pods])
    func returningToTrainingKeepsThePreviousStep(step: StudioStep) throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-entry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeTestSession(preferences: defaults.defaults)
        let project = try StudioProject.create(at: directory)
        session.project = project
        session.loadShots(for: project)
        session.step = step
        let store = try #require(session.shots)
        let job = try Data(contentsOf: directory.appendingPathComponent("job.yaml"))
        session.showShots()
        #expect(session.workspace == .shots)
        #expect(session.step == step)
        session.showTraining()
        #expect(session.workspace == .training)
        #expect(session.step == step)
        #expect(session.shots === store)
        #expect(try Data(contentsOf: directory.appendingPathComponent("job.yaml")) == job)
    }

    @Test func aTrainingDestinationLeavesShotsAtTheChosenStep() throws {
        let defaults = IsolatedDefaults()
        defer { defaults.remove() }
        let directory = temporaryTestDirectory("Shots-entry-destination")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = makeTestSession(preferences: defaults.defaults)
        let project = try StudioProject.create(at: directory)
        session.project = project
        session.loadShots(for: project)
        session.step = .concepts
        session.showShots()
        session.showTraining(.images)
        #expect(session.workspace == .training)
        #expect(session.step == .images)
    }
}
