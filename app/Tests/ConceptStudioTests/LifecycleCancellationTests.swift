import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

private actor CancelledRefreshTransport: HTTPTransport {
    private(set) var requests = 0
    private var pending: [UUID: CheckedContinuation<HTTPResponse, any Error>] = [:]

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests += 1
        let id = UUID()
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { pending[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } catch is CancellationError {
            throw URLError(.cancelled)
        }
    }

    private func cancel(_ id: UUID) {
        // URLSession reports a cancelled request this way, rather than as CancellationError.
        pending.removeValue(forKey: id)?.resume(throwing: URLError(.cancelled))
    }
}

@MainActor @Suite("Lifecycle request cancellation")
struct LifecycleCancellationTests {
    @Test func leavingTheGPUScreenDoesNotRaiseAnAlertForItsCancelledRefresh() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = CancelledRefreshTransport()
        let gpu = makeWorkspace(transport, preferences)
        gpu.provider = RunPodProvider(key: "fixture", transport: transport)
        // GPUJourneyView.task owns this refresh; navigation/reopening cancels that task.
        let screenTask = Task { await gpu.refreshOffers() }
        defer { screenTask.cancel() }
        for _ in 0 ..< 300 where await transport.requests == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.requests > 0)
        screenTask.cancel()
        await screenTask.value
        #expect(!gpu.isBusy)
        #expect(gpu.failure == nil)
        #expect(gpu.message.isEmpty)
    }

    @Test func userCancellationKeepsItsInlineResultWithoutAnErrorAlert() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = makeTestSession(preferences: preferences)
        let transport = CancelledRefreshTransport()
        session.perform("Testing a connection…") {
            _ = try await transport.send(URLRequest(url: URL(string: "https://example.invalid")!))
        }
        let work = try #require(session.task)
        defer { work.cancel() }
        for _ in 0 ..< 300 where await transport.requests == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.requests > 0)
        session.cancel()
        await work.value
        #expect(!session.busy)
        #expect(session.errorMessage == nil)
        #expect(session.message == "Cancelled. Your completed work is saved.")
    }

    @Test func realNetworkFailuresStillRaiseAlerts() async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = makeTestSession(preferences: preferences)
        session.perform("Testing a connection…") { throw URLError(.notConnectedToInternet) }
        await session.task?.value
        #expect(session.errorMessage != nil)
        await session.gpu.perform { throw URLError(.notConnectedToInternet) }
        #expect(session.gpu.failure != nil)
    }
}
