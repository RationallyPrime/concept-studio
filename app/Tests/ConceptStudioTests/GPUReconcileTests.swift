@testable import ConceptStudio
import Foundation
import Testing

@Suite("Cloud GPU records")
struct GPUReconcileTests {
    @MainActor @Test
    func aSavedCloudGPURemovedOutsideTheAppIsForgottenAtLaunch() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "EXITED", cost: 2.49, gpu: .init(count: 1)),
            started: Date(), hourlyRate: 2.49, budget: 10, trainer: "aitoolkit", runID: "old-run"
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.removePodOutside()
        let workspace = makeWorkspace(transport, preferences, readAgentToken: { _ in "token" })
        try workspace.configure(runpodKey: "test", hubToken: "", imageName: "test")
        #expect(workspace.pod?.id == "test")
        await workspace.reconcile()
        #expect(workspace.pod == nil && workspace.saved == nil)
        #expect(preferences.data(forKey: GPUWorkspace.activePodKey) == nil)
        #expect(workspace.message.contains("no longer tracks it"))
    }

    @Test
    func aProxy404BeforeTheAgentAnswersReadsAsStartingNotFailed() {
        let starting = PodAgentClient.failure(404, body: Data("404 page not found".utf8))
        #expect(starting.localizedDescription.contains("starting"))
        let agent404 = PodAgentClient.failure(404, body: Data(#"{"error":{"code":"not_found"}}"#.utf8))
        #expect(agent404.localizedDescription.contains("could not complete"))
        #expect(PodAgentClient.failure(404).localizedDescription.contains("could not complete"))
    }
}
