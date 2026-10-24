import ConceptCore
@testable import ConceptStudio
import Foundation
import Testing

@MainActor @Suite("Saved GPU rental purpose")
struct GPURentalPurposeTests {
    @Test(arguments: [false, true])
    func purposeSurvivesReopeningTheRental(_ captioning: Bool) async throws {
        let (preferences, suite) = try temporaryPreferences()
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = UnreachableAgentTransport()
        let gpu = makeWorkspace(transport, preferences)
        try gpu.configure(runpodKey: "fixture", hubToken: "fixture", imageName: "fixture")
        gpu.rentsCaptionServer = captioning
        await gpu.refreshOffers()
        await gpu.rent()
        try #require(gpu.pod)
        gpu.monitorTask?.cancel()
        await gpu.monitorTask?.value
        await gpu.stopEverything()
        // Editing the next rental's purpose must not rewrite this computer's original purpose.
        gpu.rentsCaptionServer = !captioning
        gpu.persist()
        let reopened = makeWorkspace(transport, preferences)
        try reopened.configure(runpodKey: "fixture", hubToken: "fixture", imageName: "fixture")
        reopened.monitorTask?.cancel()
        await reopened.monitorTask?.value
        #expect(reopened.rentsCaptionServer == captioning)
        #expect(reopened.saved?.rentsCaptionServer == captioning)
        await reopened.startStoppedComputer()
        #expect(reopened.hasRunningPod)
        #expect(reopened.rentsCaptionServer == captioning)
        await reopened.stopEverything()
    }
}
