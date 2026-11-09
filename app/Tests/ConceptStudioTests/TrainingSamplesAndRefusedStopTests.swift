// Samples during training, where the model's row offers them, and a cloud GPU RunPod refuses to stop.

@testable import ConceptStudio
import Foundation
import Testing

@Suite("training samples and refused stops")
struct TrainingSamplesAndRefusedStopTests {
    @MainActor @Test(arguments: [("black-forest-labs/FLUX.1-dev", true), ("Qwen/Qwen-Image-2.1", false)])
    func samplesFollowTheModelsOfferAndNameEachSubject(model: String, offered: Bool) {
        let workspace = GPUWorkspace(demoMode: true)
        workspace.chooseTrainingModel(model)
        workspace.samplesEnabled = true
        workspace.triggerWords = "NORA7, ODIN3"
        workspace.conceptClassNouns = ["NORA7": "woman"]
        let params = workspace.trainingParams(dataset: "d", inputFacts: ("plain", "NORA7, ODIN3", false))
        #expect(workspace.samplesOffered == offered)
        #expect((params["sample_every"]?.intValue ?? 0 > 0) == offered)
        #expect(params["sample_prompts"] ==
            (offered ? .array([.string("A picture of NORA7, a woman and ODIN3.")]) : nil))
        workspace.samplePrompt = "  NORA7 reading by a window  "
        let edited = workspace.trainingParams(dataset: "d", inputFacts: ("plain", "NORA7, ODIN3", false))
        #expect(edited["sample_prompts"] == (offered ? .array([.string("NORA7 reading by a window")]) : nil))
    }

    @MainActor @Test
    func aCloudGPURunPodWillNotStopCanBeForgotten() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport(failFirstStop: true)
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        await workspace.forgetActivePod()
        #expect(workspace.pod != nil) // only after RunPod refused a stop
        await workspace.stopEverything(discardingPendingResult: true)
        #expect(workspace.stopRefused)
        #expect(workspace.hasRunningPod)
        await workspace.forgetActivePod()
        #expect(workspace.pod == nil)
        #expect(!workspace.stopRefused)
        #expect(workspace.keptPods.isEmpty)
        #expect(preferences.data(forKey: GPUWorkspace.activePodKey) == nil)
        #expect(workspace.message.contains("no longer tracks cloud GPU"))
    }
}
