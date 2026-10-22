import ConceptCore
import Foundation
import Testing

@Suite("Adult content shared policy")
struct AdultContentTests {
    @Test func jobRoundTripAndDerivedConcepts() throws {
        let person = try Concept(trigger: "IDENTITY", targetConcept: .fullIdentity)
        var job = try Job(concepts: [person], adultContent: true)
        #expect(try Job.load(yaml: job.dump()) == job)
        #expect(person.attributesToDescribe.contains("state of dress or undress"))
        #expect(job.captionConcept(person).attributesToDescribe
            .contains("sexual activity and any other people involved"))
        #expect(!person.attributesToDescribe.contains("sexual activity and any other people involved"))
        #expect(job.sampleView(mapping: ["IDENTITY": "the woman"]).objectValue?["adult_content"] == .bool(true))
        job.adultContent = false
        #expect(job.captionConcept(person) == person)
        #expect(try Job.load(yaml: "concepts: []").adultContent == false)
    }

    @Test(arguments: [true, false]) func publishingChecksActualRepositoryPrivacy(isPrivate: Bool) async throws {
        let client = HubClient(token: "test", transport: PrivacyTransport(isPrivate: isPrivate))
        if isPrivate {
            try await client.requirePrivateDataset(RepoID("test/dataset"))
        } else {
            await #expect(throws: ConfigurationError.self) {
                try await client.requirePrivateDataset(RepoID("test/dataset"))
            }
        }
    }
}

private struct PrivacyTransport: HTTPTransport {
    let isPrivate: Bool
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        #expect(request.url?.path == "/api/datasets/test/dataset")
        return HTTPResponse(status: 200, body: Data("{\"private\":\(isPrivate)}".utf8))
    }
}
