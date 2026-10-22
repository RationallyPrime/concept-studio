@testable import ConceptStudio
import Foundation
import Testing

@Suite("Cloud GPU records")
struct GPUReconcileTests {
    /// RunPod answers "no such pod" both for a deleted pod and for one in another account, so the record is
    /// forgotten only when the pod was rented under the key now in use.
    @MainActor @Test(arguments: ["test", "other-account"])
    func aSavedCloudGPURemovedOutsideTheAppIsForgottenOnlyUnderItsOwnKey(_ key: String) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let saved = SavedPod(
            pod: RentedPod(id: "test", status: "EXITED", cost: 2.49, gpu: .init(count: 1)),
            started: Date(), hourlyRate: 2.49, budget: 10, trainer: "aitoolkit", runID: "old-run",
            runpodKey: SavedPod.fingerprint("test")
        )
        try preferences.set(JSONEncoder().encode(saved), forKey: GPUWorkspace.activePodKey)
        let transport = UnreachableAgentTransport(agentAvailable: true)
        await transport.removePodOutside()
        let workspace = makeWorkspace(transport, preferences, readAgentToken: { _ in "token" })
        try workspace.configure(runpodKey: key, hubToken: "", imageName: "test")
        #expect(workspace.pod?.id == "test")
        await workspace.reconcile()
        if key == "test" {
            #expect(workspace.pod == nil && workspace.saved == nil)
            #expect(preferences.data(forKey: GPUWorkspace.activePodKey) == nil)
            #expect(workspace.message.contains("no longer tracks it"))
        } else {
            #expect(workspace.pod?.id == "test")
            #expect(preferences.data(forKey: GPUWorkspace.activePodKey) != nil)
            #expect(workspace.message.contains("another RunPod account"))
        }
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
