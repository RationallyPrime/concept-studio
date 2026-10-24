import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@MainActor @Suite("GPU boot and idle timing")
struct GPUReadinessTests {
    private func rent(
        _ transport: UnreachableAgentTransport, preferences: UserDefaults
    ) async throws -> GPUWorkspace {
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "fixture", hubToken: "", imageName: "fixture")
        workspace.chooseTrainingModel(ungatedModel)
        await workspace.refreshOffers()
        await workspace.rent()
        try #require(workspace.pod)
        workspace.monitorTask?.cancel()
        await workspace.monitorTask?.value
        return workspace
    }

    @Test func bootTimeIsExcludedAndOnlyTheFirstAnswerStartsTheIdleClock() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = try await rent(transport, preferences: preferences)
        workspace.idleMinutes = 1
        workspace.lastActivity = .distantPast
        workspace.saved?.started = Date().addingTimeInterval(-1800)
        await workspace.refresh()
        #expect(workspace.hasRunningPod)
        #expect(workspace.agentReadyAt == nil)
        #expect(await transport.stopCalls == 0)

        await transport.agentReachable(true)
        let before = Date()
        await workspace.refresh()
        let ready = try #require(workspace.agentReadyAt)
        #expect(ready >= before)
        #expect(workspace.lastActivity == ready)
        #expect(workspace.hasRunningPod)
        await workspace.refresh()
        #expect(workspace.agentReadyAt == ready)
        #expect(workspace.lastActivity == ready)

        workspace.lastActivity = Date().addingTimeInterval(-120)
        await workspace.refresh()
        #expect(!workspace.hasRunningPod)
        #expect(await transport.stopCalls == 1)
    }

    @Test func spendingLimitStillStopsBootingGPUWithKeepRunningEnabled() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = try await rent(transport, preferences: preferences)
        workspace.keepsRunningWhenIdle = true
        workspace.saved?.budget = 0.01
        workspace.saved?.started = Date().addingTimeInterval(-3600)
        await workspace.refresh()
        #expect(!workspace.hasRunningPod)
        #expect(workspace.agentReadyAt == nil)
        #expect(await transport.stopCalls == 1)
        #expect(workspace.message.contains("spending limit"))
    }

    @Test(arguments: [false, true])
    func readinessSurvivesReopeningWithAnUnreachableAgent(_ wasReady: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = try await rent(transport, preferences: preferences)
        if wasReady {
            await transport.agentReachable(true)
            await workspace.refresh()
            await transport.agentReachable(false)
        }
        workspace.persist()
        let data = try #require(preferences.data(forKey: GPUWorkspace.activePodKey))
        let record = try JSONDecoder().decode(SavedPod.self, from: data)
        #expect((record.agentReadyAt != nil) == wasReady)

        let reopened = makeWorkspace(transport, preferences)
        try reopened.configure(runpodKey: "fixture", hubToken: "", imageName: "fixture")
        reopened.monitorTask?.cancel()
        await reopened.monitorTask?.value
        #expect(reopened.agentReadyAt == record.agentReadyAt)
        reopened.idleMinutes = 0
        await reopened.refresh()
        #expect(reopened.hasRunningPod == !wasReady)
        await reopened.stopEverything()
    }

    @Test(arguments: [false, true])
    func restartingTheSameOrKeptPodNeedsAnewAgentAnswer(_ kept: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = try await rent(transport, preferences: preferences)
        await transport.agentReachable(true)
        await workspace.refresh()
        #expect(workspace.agentReadyAt != nil && workspace.plan != nil)
        await workspace.stopEverything()
        await transport.agentReachable(false)
        if kept {
            let id = try #require(workspace.pod?.id)
            await workspace.keepStoppedPod()
            await workspace.startKeptPod(id: id)
        } else {
            await workspace.startStoppedComputer()
        }
        workspace.monitorTask?.cancel()
        await workspace.monitorTask?.value
        #expect(workspace.hasRunningPod)
        #expect(workspace.agentReadyAt == nil)
        #expect(workspace.plan == nil)
        #expect(workspace.saved?.agentReadyAt == nil)
        workspace.idleMinutes = 0
        await workspace.refresh()
        #expect(workspace.hasRunningPod)
        await workspace.stopEverything()
    }

    @Test func aReplyFromBeforeRestartCannotMakeTheNewStartReady() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = try await rent(transport, preferences: preferences)
        let previousAgent = HistoryAgent()
        workspace.agent = previousAgent
        await previousAgent.pauseNextPlanRead()
        let refresh = Task { await workspace.refresh() }
        await previousAgent.waitForPausedPlanRead()
        await workspace.stopEverything()
        await workspace.startStoppedComputer()
        workspace.monitorTask?.cancel()
        await previousAgent.releasePlanRead()
        await refresh.value
        await workspace.monitorTask?.value
        #expect(workspace.hasRunningPod)
        #expect(workspace.plan == nil)
        #expect(workspace.agentReadyAt == nil)
        #expect(workspace.saved?.agentReadyAt == nil)
        await workspace.stopEverything()
    }

    @Test
    func idleStopStillRunsWhenAgentReturns522() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        await workspace.monitorTask?.value
        await transport.agentReachable(true)
        await workspace.refresh()
        #expect(workspace.agentReadyAt != nil)
        await transport.agentReachable(false)
        workspace.idleMinutes = 0
        await workspace.refresh()
        for _ in 0 ..< 100 where workspace.hasRunningPod {
            try await Task.sleep(for: .milliseconds(10))
            await workspace.refresh()
        }
        #expect(workspace.pod?.status == "EXITED")
        #expect(await transport.stopCalls == 1)
    }

    @Test
    func keepRunningWhileIdleSkipsTheIdleStopAndSurvivesReopening() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let workspace = makeWorkspace(transport, preferences)
        try workspace.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        await workspace.refreshOffers()
        await workspace.rent()
        workspace.monitorTask?.cancel()
        await workspace.monitorTask?.value
        await transport.agentReachable(true)
        await workspace.refresh()
        #expect(workspace.agentReadyAt != nil)
        await transport.agentReachable(false)
        workspace.keepsRunningWhenIdle = true
        workspace.idleMinutes = 0
        workspace.lastActivity = .distantPast
        await workspace.refresh()
        #expect(workspace.hasRunningPod)
        #expect(await transport.stopCalls == 0)
        let reopened = makeWorkspace(UnreachableAgentTransport(), preferences)
        try reopened.configure(runpodKey: "test", hubToken: "test", imageName: "test")
        #expect(reopened.keepsRunningWhenIdle)
        await workspace.stopEverything()
    }
}
