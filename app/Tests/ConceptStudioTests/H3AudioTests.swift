import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@Suite("H3 clip audio choice")
@MainActor
struct H3AudioTests {
    @Test func repeatingAnotherModelPreservesTheProjectsH3AudioChoice() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences.defaults)
        workspace.projectFolder = project.directory
        workspace.trainAudio = false
        let run = TrainingRun(
            runID: "earlier-image-run", trainer: "aitoolkit", datasetRepo: "synthetic/stills",
            datasetContainsVideo: false, paramsJSON: JSONValue.object([
                "base_model": .string("black-forest-labs/FLUX.1-dev"), "steps": .int(6), "rank": .int(4),
            ]).pythonDumpsData(), volumeID: "storage", startedAt: Date(), updatedAt: Date(), podSpendAtStart: 0
        )
        workspace.runHistory = [run]
        workspace.repeatSettings(from: run)
        #expect(!workspace.trainAudio)
        workspace.chooseTrainingModel(GPUWorkspace.h3BaseModel)
        #expect(!workspace.trainAudio)
        let reopened = makeWorkspace(UnreachableAgentTransport(), preferences.defaults)
        reopened.projectFolder = project.directory
        #expect(!reopened.trainAudio)
    }

    @Test func choiceIsProjectLocalAndDefaultsOn() async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let first = try await makeDemoProject()
        let second = try await makeDemoProject()
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let workspace = makeWorkspace(UnreachableAgentTransport(), preferences.defaults)
        workspace.projectFolder = first.directory
        #expect(workspace.trainAudio)
        workspace.trainAudio = false
        #expect(workspace.saveProjectRecord())
        workspace.projectFolder = second.directory
        #expect(workspace.trainAudio)
        workspace.projectFolder = first.directory
        #expect(!workspace.trainAudio)
        let reopened = makeWorkspace(UnreachableAgentTransport(), preferences.defaults)
        reopened.projectFolder = first.directory
        #expect(!reopened.trainAudio)
        let oldRecord = try JSONDecoder().decode(ProjectTrainingRecord.self, from: Data("{}".utf8))
        #expect(oldRecord.trainAudio)
    }

    @Test(arguments: [false, true])
    func trainingRepeatAndResumeKeepTheRecordedChoice(audio: Bool) async throws {
        let preferences = IsolatedDefaults()
        defer { preferences.remove() }
        let project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        let agent = H3TestAgent()
        let workspace = H3TrainingTests.connected(preferences.defaults, folder: project.directory, agent: agent)
        workspace.chooseTrainingModel(GPUWorkspace.h3BaseModel)
        workspace.regularizationOn = false
        workspace.datasetContainsVideo = true
        workspace.profile = "h3-video"
        workspace.trainAudio = audio
        await workspace.train(datasetRepo: "synthetic/clips")
        #expect(workspace.failure == nil)
        let start = try #require(await agent.starts.last { $0.service == "trainer-aitoolkit" })
        #expect(start.params["train_audio"] == .bool(audio))
        let run = try #require(workspace.runHistory.last)
        #expect(run.trainsAudio == audio)
        #expect(run.params["train_audio"] == .bool(audio))
        workspace.trainingState = "exited"
        workspace.trainAudio = !audio
        workspace.repeatSettings(from: run)
        #expect(workspace.trainAudio == audio)
        #expect(ProjectTrainingRecord.load(from: project.directory).trainAudio == audio)
        workspace.trainAudio = !audio
        await workspace.resumeRun(run, totalSteps: run.targetSteps + 1)
        #expect(workspace.failure == nil)
        let continuation = try #require(await agent.starts.last { $0.service == "trainer-aitoolkit" })
        #expect(continuation.params["resume"] == .bool(true))
        #expect(continuation.params["train_audio"] == .bool(audio))
        var stillRun = run
        stillRun.datasetContainsVideo = false
        #expect(!stillRun.trainsAudio)
    }

    @Test func audioOffSuggestsNAWithoutChangingSavedPoliciesOrOtherProfiles() async throws {
        let session = makeTestSession()
        var project = try await makeDemoProject()
        defer { try? FileManager.default.removeItem(at: project.directory) }
        project.job.profile = "h3-video"
        project.job.policyOverrides["custom"] = "Keep this project's custom instructions."
        project.images.append(ProjectImage(url: project.imagesDirectory.appendingPathComponent("clip.mp4")))
        session.project = project
        session.gpu.trainAudio = false
        #expect(session.hasH3Clips)
        // Review's comparison uses its own endpoint. Unfinished main/reviewer settings must not block it.
        session.modelName = ""
        session.useCritic = true
        session.criticModel = ""
        #expect(throws: (any Error).self) { try session.jobForCaptioning() }
        let execution = try session.applyingTrainingAudioPolicy(to: #require(session.project?.job))
        #expect(execution.policyOverrides["h3_audio_training"] == StudioSession.h3AudioCaptionPolicy)
        #expect(execution.policyOverrides["custom"] == project.job.policyOverrides["custom"])
        session.modelName = "synthetic-caption-model"
        session.useCritic = false
        #expect(try session.jobForCaptioning().policyOverrides == project.job.policyOverrides)
        #expect(session.project?.job.policyOverrides == project.job.policyOverrides)
        session.gpu.trainAudio = true
        #expect(try session.applyingTrainingAudioPolicy(to: #require(session.project?.job)).policyOverrides == project
            .job
            .policyOverrides)
        session.gpu.trainAudio = false
        session.project?.job.profile = "ltx-video"
        #expect(!session.hasH3Clips)
        #expect(try session.applyingTrainingAudioPolicy(to: #require(session.project?.job)).policyOverrides == project
            .job
            .policyOverrides)
        session.project?.job.profile = "h3-still"
        #expect(!session.hasH3Clips)
        #expect(try session.applyingTrainingAudioPolicy(to: #require(session.project?.job)).policyOverrides == project
            .job
            .policyOverrides)
    }
}
